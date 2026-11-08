// Package server runs the promoter inside a tier cluster: Flux notifies it
// when an app's Kustomization/HelmRelease reconciles successfully, it runs
// the evidence gate on its own cluster, records the outcome, and (if the gate
// passes on every cluster of the tier) opens the next tier's PR. A periodic
// re-check covers missed events.
package server

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/twallac10/platform-promoter/internal/config"
	"github.com/twallac10/platform-promoter/internal/ledger"
	"github.com/twallac10/platform-promoter/internal/promote"
	"github.com/twallac10/platform-promoter/internal/release"
)

// Throttles for re-running a gate whose result is already recorded.
var (
	RetryFailedOnEvent = 2 * time.Minute  // a new reconcile may have fixed it
	RetryFailedOnTick  = 30 * time.Minute // periodic retry of a failed gate
	RetryStale         = 15 * time.Minute // in_progress with nobody running it (crash)
	ReopenPR           = 6 * time.Hour    // passed, but the next tier still lacks it
)

type Server struct {
	Promoter *promote.Promoter // Contexts must be [Cluster]
	Fleet    *config.Fleet
	Ledger   ledger.Ledger
	Tier     config.Tier
	Cluster  string // this cluster's name in tiers.yaml
	Secret   []byte // HMAC key shared with the Flux Provider
	Interval time.Duration
	Log      *slog.Logger
	Now      func() time.Time

	mu      sync.Mutex
	queue   chan job
	pending map[string]bool
	last    map[string]time.Time // last gate run per app
	running string
}

type job struct{ app, trigger string }

func (s *Server) init() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.queue == nil {
		s.queue = make(chan job, 64)
		s.pending = map[string]bool{}
		s.last = map[string]time.Time{}
	}
	if s.Log == nil {
		s.Log = slog.Default()
	}
	if s.Now == nil {
		s.Now = time.Now
	}
}

// Handler serves /healthz and /hook.
func (s *Server) Handler() http.Handler {
	s.init()
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok\n")) })
	mux.HandleFunc("POST /hook", s.hook)
	return mux
}

// Event is the subset of a Flux notification event we use.
type Event struct {
	InvolvedObject struct {
		Kind      string `json:"kind"`
		Namespace string `json:"namespace"`
		Name      string `json:"name"`
	} `json:"involvedObject"`
	Severity string            `json:"severity"`
	Reason   string            `json:"reason"`
	Message  string            `json:"message"`
	Metadata map[string]string `json:"metadata"`
}

var successReasons = map[string]bool{
	"ReconciliationSucceeded": true, // Kustomization (after health checks, wait: true)
	"InstallSucceeded":        true, // HelmRelease
	"UpgradeSucceeded":        true,
	"TestSucceeded":           true,
}

func (s *Server) hook(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "read body", http.StatusBadRequest)
		return
	}
	if !VerifySignature(s.Secret, body, r.Header.Get("X-Signature")) {
		http.Error(w, "bad signature", http.StatusUnauthorized)
		return
	}
	var ev Event
	if err := json.Unmarshal(body, &ev); err != nil {
		http.Error(w, "bad event", http.StatusBadRequest)
		return
	}
	app, ok := s.appFor(ev)
	if !ok || ev.Severity == "error" || !successReasons[ev.Reason] {
		w.WriteHeader(http.StatusAccepted)
		return
	}
	s.Log.Info("event", "app", app, "kind", ev.InvolvedObject.Kind, "reason", ev.Reason)
	s.Enqueue(app, "event")
	w.WriteHeader(http.StatusAccepted)
}

// appFor maps an event to an app: the fleet's Kustomization flux-system/<app>
// or the app's HelmRelease <namespace>/<app>.
func (s *Server) appFor(ev Event) (string, bool) {
	o := ev.InvolvedObject
	for _, a := range s.Fleet.Apps {
		switch {
		case o.Kind == "Kustomization" && o.Namespace == "flux-system" && o.Name == a.Name:
			return a.Name, true
		case o.Kind == "HelmRelease" && o.Namespace == a.Namespace && o.Name == a.Name:
			return a.Name, true
		}
	}
	return "", false
}

// VerifySignature checks Flux's generic-hmac header ("sha256=<hex>").
func VerifySignature(secret, body []byte, header string) bool {
	if len(secret) == 0 {
		return false // refuse unsigned operation
	}
	algo, sig, ok := strings.Cut(header, "=")
	if !ok || algo != "sha256" {
		return false
	}
	want, err := hex.DecodeString(sig)
	if err != nil {
		return false
	}
	m := hmac.New(sha256.New, secret)
	m.Write(body)
	return hmac.Equal(m.Sum(nil), want)
}

// Enqueue schedules a decision for app (deduplicated while queued).
func (s *Server) Enqueue(app, trigger string) {
	s.init()
	s.mu.Lock()
	if s.pending[app] {
		s.mu.Unlock()
		return
	}
	s.pending[app] = true
	s.mu.Unlock()
	select {
	case s.queue <- job{app, trigger}:
	default:
		s.mu.Lock()
		delete(s.pending, app)
		s.mu.Unlock()
		s.Log.Warn("queue full, dropping (the periodic re-check will catch it)", "app", app)
	}
}

// Run processes the queue one app at a time and re-checks every app each
// Interval. It returns when ctx is done.
func (s *Server) Run(ctx context.Context) {
	s.init()
	tick := time.NewTicker(s.Interval)
	defer tick.Stop()
	s.enqueueAll("startup")
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			s.enqueueAll("tick")
		case j := <-s.queue:
			s.mu.Lock()
			delete(s.pending, j.app)
			s.mu.Unlock()
			s.Process(ctx, j.app, j.trigger)
		}
	}
}

func (s *Server) enqueueAll(trigger string) {
	for _, a := range s.Fleet.Apps {
		s.Enqueue(a.Name, trigger)
	}
}

// Process decides whether app needs a gate run here and runs it.
func (s *Server) Process(ctx context.Context, appName, trigger string) {
	s.init()
	app, err := s.Fleet.App(appName)
	if err != nil {
		s.Log.Error("unknown app", "app", appName)
		return
	}
	run, why, err := s.Decide(ctx, app, trigger)
	if err != nil {
		s.Log.Error("decide", "app", app.Name, "err", err)
		return
	}
	if !run {
		s.Log.Debug("nothing to do", "app", app.Name, "why", why)
		return
	}
	s.mu.Lock()
	s.last[app.Name] = s.Now()
	s.running = app.Name
	s.mu.Unlock()
	defer func() { s.mu.Lock(); s.running = ""; s.mu.Unlock() }()
	s.Log.Info("gate", "app", app.Name, "tier", s.Tier.Name, "why", why, "trigger", trigger)

	if _, ok, _ := s.Fleet.Next(s.Tier.Name); !ok {
		res, err := s.Promoter.Check(ctx, app.Name, s.Tier.Name)
		s.logResult(app.Name, res, "", err)
		return
	}
	url, res, err := s.Promoter.Promote(ctx, app.Name, s.Tier.Name)
	s.logResult(app.Name, res, url, err)
}

func (s *Server) logResult(app string, res *promote.Result, url string, err error) {
	var gf *promote.GateFailedError
	switch {
	case errors.As(err, &gf):
		s.Log.Warn("gate failed; no PR", "app", app, "err", err)
	case err != nil:
		s.Log.Error("gate error", "app", app, "err", err)
	case url != "":
		s.Log.Info("promotion PR", "app", app, "url", url)
	case res != nil && res.Passed():
		s.Log.Info("gate passed", "app", app)
	}
}

// Decide: run when this cluster has no finished gate for the release main
// says this tier runs, retry failures and stale runs with backoff, and
// re-attempt the PR if the gate passed but the next tier still lacks it.
func (s *Server) Decide(ctx context.Context, app config.App, trigger string) (bool, string, error) {
	path := "tiers/" + s.Tier.Name + "/release.yaml"
	raw, ok, err := s.Ledger.File(ctx, app.Repo, path, "main")
	if err != nil || !ok {
		return false, "", errOr(err, path+" missing")
	}
	rel, err := release.Parse(raw)
	if err != nil {
		return false, "", err
	}
	d, err := s.Ledger.LatestDeployment(ctx, app.Repo, s.Tier.Name, app.Name, s.Cluster, false)
	if err != nil {
		return false, "", err
	}
	s.mu.Lock()
	since := s.Now().Sub(s.last[app.Name])
	running := s.running == app.Name
	s.mu.Unlock()
	switch {
	case running:
		return false, "already running", nil
	case d == nil || d.Payload.Digest != rel.Digest:
		return true, "no gate yet for " + rel.ShortDigest(), nil
	case d.State == "in_progress" || d.State == "queued" || d.State == "pending":
		return since > RetryStale, "stale " + d.State + " gate", nil
	case d.State == "success":
		next, ok, _ := s.Fleet.Next(s.Tier.Name)
		if !ok {
			return false, "passed (last tier)", nil
		}
		nraw, _, err := s.Ledger.File(ctx, app.Repo, "tiers/"+next.Name+"/release.yaml", "main")
		if err != nil {
			return false, "", err
		}
		if bytes.Equal(nraw, raw) {
			return false, "already promoted to " + next.Name, nil
		}
		return since > ReopenPR, "passed; " + next.Name + " still behind", nil
	default: // failure, error
		limit := RetryFailedOnTick
		if trigger == "event" {
			limit = RetryFailedOnEvent
		}
		return since > limit, "retry after " + d.State, nil
	}
}

func errOr(err error, msg string) error {
	if err != nil {
		return err
	}
	return errors.New(msg)
}
