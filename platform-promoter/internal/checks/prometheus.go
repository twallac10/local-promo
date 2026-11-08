package checks

import (
	"context"
	"fmt"
	"io"
	"math"
	"net/http"
	"sort"
	"strings"

	"github.com/twallac10/platform-promoter/internal/cluster"
	"github.com/twallac10/platform-promoter/internal/gate"
)

// Check set "prometheus": evidence that monitoring itself works, using the
// canary app (podinfo in ns canary) as the witness that discovery -> scrape ->
// query works end to end. Prometheus discovers pods annotated
// prometheus.io/scrape=true (job "kubernetes-pods").

func init() {
	Register("prometheus", func() []gate.Check {
		return []gate.Check{
			&PromReady{},
			&PromCanaryScraped{},
			&PromTargetsUp{},
			&PromRuleEvalFailures{},
		}
	})
}

const (
	promHRNamespace = PromNamespace
	promHRName      = "prometheus"

	promCanaryNS  = "canary"
	promCanaryJob = "kubernetes-pods" // annotation-based pod discovery
	promCanaryApp = "podinfo"         // pod label app.kubernetes.io/name, mapped to app_kubernetes_io_name
)

// promWindow is max(ceil(time since the HelmRelease became Ready), 60s) as a
// PromQL range, e.g. "[245s]". ok=false while the HelmRelease is not Ready.
func promWindow(ctx context.Context, env *gate.Env) (win string, reason string, ok bool) {
	hr, err := env.Cluster.Get(ctx, cluster.HelmRelease, promHRNamespace, promHRName)
	if err != nil {
		return "", "helmrelease " + promHRNamespace + "/" + promHRName + ": " + err.Error(), false
	}
	if st, r, _, _ := cluster.Condition(hr, "Ready"); st != "True" {
		return "", fmt.Sprintf("HelmRelease not Ready (%s)", r), false
	}
	t, found := cluster.ConditionTime(hr, "Ready")
	if !found {
		return "", "HelmRelease has no Ready lastTransitionTime", false
	}
	secs := int(math.Ceil(env.Since(t).Seconds()))
	if secs < 60 {
		secs = 60
	}
	return fmt.Sprintf("[%ds]", secs), "", true
}

// ---- 1. Prometheus ready ----

type PromReady struct{}

func (*PromReady) Name() string { return "prometheus ready" }

func (*PromReady) Run(ctx context.Context, env *gate.Env) gate.Result {
	q := fmt.Sprintf("GET http://%s.%s:%d/-/ready", PromService, PromNamespace, PromPort)
	base, done, err := env.Cluster.HTTP.BaseURL(ctx, PromNamespace, PromService, PromPort)
	if err != nil {
		return pending("reach prometheus: "+err.Error(), q)
	}
	defer done()
	code, body, err := promDo(ctx, http.MethodGet, base+"/-/ready", nil, nil)
	if err != nil {
		return pending(err.Error(), q)
	}
	if code != http.StatusOK {
		return pending(fmt.Sprintf("/-/ready returned %d: %s", code, strings.TrimSpace(string(body))), q)
	}
	return pass("/-/ready 200", q)
}

// ---- 2. canary scraped ----

type PromCanaryScraped struct{}

func (*PromCanaryScraped) Name() string { return "canary scraped since Ready" }

func (*PromCanaryScraped) Run(ctx context.Context, env *gate.Env) gate.Result {
	win, reason, ok := promWindow(ctx, env)
	if !ok {
		return pending(reason, "kubectl -n prometheus get helmrelease prometheus")
	}
	sel := fmt.Sprintf(`up{namespace=%q,job=%q,app_kubernetes_io_name=%q}`, promCanaryNS, promCanaryJob, promCanaryApp)
	q := fmt.Sprintf("sum_over_time(%s%s)", sel, win)
	cur, err := PromQuery(ctx, env, sel)
	if err != nil {
		return pending(err.Error(), q)
	}
	if len(cur) == 0 {
		return pending("canary target not discovered", q)
	}
	scrapes, found, err := PromScalar(ctx, env, q)
	if err != nil {
		return pending(err.Error(), q)
	}
	if !found {
		return pending("canary target not discovered", q)
	}
	min := env.Gate.MinScrapes
	if int(scrapes) < min {
		return pending(fmt.Sprintf("%d/%d scrapes since Ready", int(scrapes), min), q)
	}
	up := cur[0].Value
	val := fmt.Sprintf("%d scrapes, up=%g", int(scrapes), up)
	if up != 1 {
		return pending(fmt.Sprintf("canary target is down (up=%g)", up), q)
	}
	return pass(val, q)
}

// ---- 3. all targets up ----

type PromTargetsUp struct{}

func (*PromTargetsUp) Name() string { return "all scrape targets up" }

func (*PromTargetsUp) Run(ctx context.Context, env *gate.Env) gate.Result {
	const qDown, qAll = `count(up == 0)`, `count(up)`
	down, found, err := PromScalar(ctx, env, qDown)
	if err != nil {
		return pending(err.Error(), qDown)
	}
	if found && down > 0 {
		jobs := map[string]bool{}
		if s, err := PromQuery(ctx, env, `up == 0`); err == nil {
			for _, x := range s {
				jobs[x.Labels["job"]] = true
			}
		}
		var names []string
		for j := range jobs {
			names = append(names, j)
		}
		sort.Strings(names)
		return gate.Result{Status: gate.Pending, Value: fmt.Sprintf("%d targets down", int(down)),
			Reason: fmt.Sprintf("%d targets down: %s", int(down), strings.Join(names, ", ")), Query: qDown}
	}
	total, found, err := PromScalar(ctx, env, qAll)
	if err != nil {
		return pending(err.Error(), qAll)
	}
	if !found || total == 0 {
		return pending("no scrape targets yet", qAll)
	}
	return pass(fmt.Sprintf("%d targets up", int(total)), qDown+" == 0 of "+qAll)
}

// ---- 4. rule evaluation failures ----

type PromRuleEvalFailures struct{}

func (*PromRuleEvalFailures) Name() string { return "no rule evaluation failures" }

func (*PromRuleEvalFailures) Run(ctx context.Context, env *gate.Env) gate.Result {
	win, reason, ok := promWindow(ctx, env)
	if !ok {
		return pending(reason, "kubectl -n prometheus get helmrelease prometheus")
	}
	q := fmt.Sprintf("sum(increase(prometheus_rule_evaluation_failures_total%s))", win)
	v, _, err := PromScalar(ctx, env, q) // empty result = no failures recorded
	if err != nil {
		return pending(err.Error(), q)
	}
	if v > 0 {
		return fail(fmt.Sprintf("%g rule evaluation failures since Ready", v), fmt.Sprintf("%g failures", v), q)
	}
	return pass("0 failures", q)
}

// ---- HTTP helpers ----
func promDo(ctx context.Context, method, u string, body io.Reader, hdr http.Header) (int, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, method, u, body)
	if err != nil {
		return 0, nil, err
	}
	for k, v := range hdr {
		req.Header[k] = v
	}
	resp, err := cluster.Client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	return resp.StatusCode, b, nil
}
func truncStr(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
