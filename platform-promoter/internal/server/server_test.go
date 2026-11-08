package server

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/twallac10/platform-promoter/internal/config"
	"github.com/twallac10/platform-promoter/internal/ledger"
)

const dA = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const dB = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

func rel(d string) []byte {
	return []byte("kind: OCIRepository\nspec:\n  ref:\n    digest: \"" + d + "\"\n")
}

type fakeLedger struct {
	ledger.Ledger
	files map[string][]byte
	dep   *ledger.Deployment
}

func (f *fakeLedger) File(_ context.Context, _, path, _ string) ([]byte, bool, error) {
	b, ok := f.files[path]
	return b, ok, nil
}
func (f *fakeLedger) LatestDeployment(context.Context, string, string, string, string, bool) (*ledger.Deployment, error) {
	return f.dep, nil
}

func newServer(t *testing.T, tier string) (*Server, *fakeLedger, *time.Time) {
	fleet, err := config.Parse(
		[]byte("tiers:\n- {name: dev, clusters: [kind-tier-dev]}\n- {name: stg, clusters: [kind-tier-stg]}\n"),
		[]byte("owner: o\napps:\n- {name: kyverno, repo: platform-kyverno, namespace: kyverno}\n"))
	if err != nil {
		t.Fatal(err)
	}
	tr, _ := fleet.Tier(tier)
	fl := &fakeLedger{files: map[string][]byte{"tiers/dev/release.yaml": rel(dB), "tiers/stg/release.yaml": rel(dA)}}
	now := time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC)
	s := &Server{Fleet: fleet, Ledger: fl, Tier: tr, Cluster: tr.Clusters[0], Secret: []byte("k"), Interval: time.Minute,
		Now: func() time.Time { return now }}
	s.init()
	return s, fl, &now
}

func decide(t *testing.T, s *Server, trigger string) bool {
	t.Helper()
	app, _ := s.Fleet.App("kyverno")
	run, why, err := s.Decide(context.Background(), app, trigger)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("run=%v why=%s", run, why)
	return run
}

func TestDecide(t *testing.T) {
	s, fl, now := newServer(t, "dev")
	// Nothing recorded for this digest yet: run.
	if !decide(t, s, "event") {
		t.Fatal("want run for a new release")
	}
	// Recorded for an older digest: run.
	fl.dep = &ledger.Deployment{State: "success", Payload: ledger.Payload{Digest: dA}}
	if !decide(t, s, "tick") {
		t.Fatal("want run for a newer digest")
	}
	// Passed and stg still behind, but we just ran: wait for ReopenPR.
	fl.dep = &ledger.Deployment{State: "success", Payload: ledger.Payload{Digest: dB}}
	s.last["kyverno"] = *now
	if decide(t, s, "tick") {
		t.Fatal("must not re-gate right after a pass")
	}
	*now = now.Add(ReopenPR + time.Minute)
	if !decide(t, s, "tick") {
		t.Fatal("want a re-attempt once ReopenPR passed")
	}
	// Promoted already: nothing to do.
	fl.files["tiers/stg/release.yaml"] = rel(dB)
	if decide(t, s, "tick") {
		t.Fatal("already promoted")
	}
	// Failed: an event retries sooner than a tick.
	fl.dep = &ledger.Deployment{State: "failure", Payload: ledger.Payload{Digest: dB}}
	s.last["kyverno"] = *now
	*now = now.Add(RetryFailedOnEvent + time.Second)
	if !decide(t, s, "event") || decide(t, s, "tick") {
		t.Fatal("failure retry throttles")
	}
}

func TestDecideLastTierDoesNotPromote(t *testing.T) {
	s, fl, _ := newServer(t, "stg")
	fl.dep = &ledger.Deployment{State: "success", Payload: ledger.Payload{Digest: dA}}
	if decide(t, s, "tick") {
		t.Fatal("last tier with a passed gate has nothing to do")
	}
}

func sign(body []byte, key string) string {
	m := hmac.New(sha256.New, []byte(key))
	m.Write(body)
	return "sha256=" + hex.EncodeToString(m.Sum(nil))
}

func TestHook(t *testing.T) {
	s, _, _ := newServer(t, "dev")
	h := s.Handler()
	post := func(body, sig string) int {
		r := httptest.NewRequest(http.MethodPost, "/hook", bytes.NewBufferString(body))
		r.Header.Set("X-Signature", sig)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w.Code
	}
	ok := `{"involvedObject":{"kind":"Kustomization","namespace":"flux-system","name":"kyverno"},"severity":"info","reason":"ReconciliationSucceeded"}`
	if c := post(ok, "sha256=00"); c != http.StatusUnauthorized {
		t.Fatalf("bad signature accepted: %d", c)
	}
	if c := post(ok, sign([]byte(ok), "k")); c != http.StatusAccepted || !s.pending["kyverno"] {
		t.Fatalf("code %d pending %v", c, s.pending)
	}
	// Duplicate while queued is coalesced.
	post(ok, sign([]byte(ok), "k"))
	if len(s.queue) != 1 {
		t.Fatalf("queue len %d", len(s.queue))
	}
	// Failures and unrelated objects are ignored.
	s, _, _ = newServer(t, "dev")
	h = s.Handler()
	for _, b := range []string{
		`{"involvedObject":{"kind":"HelmRelease","namespace":"kyverno","name":"kyverno"},"severity":"error","reason":"UpgradeFailed"}`,
		`{"involvedObject":{"kind":"Kustomization","namespace":"flux-system","name":"canary"},"severity":"info","reason":"ReconciliationSucceeded"}`,
	} {
		post(b, sign([]byte(b), "k"))
	}
	if len(s.queue) != 0 {
		t.Fatal("ignored events were queued")
	}
	// HelmRelease success in the app namespace maps to the app.
	b := `{"involvedObject":{"kind":"HelmRelease","namespace":"kyverno","name":"kyverno"},"severity":"info","reason":"UpgradeSucceeded"}`
	post(b, sign([]byte(b), "k"))
	if len(s.queue) != 1 {
		t.Fatal("HelmRelease success not queued")
	}
}

func TestVerifySignatureRequiresSecret(t *testing.T) {
	if VerifySignature(nil, []byte("x"), sign([]byte("x"), "")) {
		t.Fatal("empty secret must never verify")
	}
}
