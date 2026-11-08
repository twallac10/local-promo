package checks

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"k8s.io/apimachinery/pkg/runtime"

	"github.com/twallac10/platform-promoter/internal/gate"
)

// promHR is the prometheus HelmRelease; Ready since 11:50:00, the
// fake clock is 12:00:00, so the window is 600s.
func promHR(ready string) runtime.Object {
	return u(map[string]any{
		"apiVersion": "helm.toolkit.fluxcd.io/v2", "kind": "HelmRelease",
		"metadata": map[string]any{"name": "prometheus", "namespace": "prometheus"},
		"status":   map[string]any{"conditions": readyCond(ready)},
	})
}

const promWin = "[600s]"

func promSvc(ready int, answers map[string][]Sample) fakeServices {
	mux := http.NewServeMux()
	mux.HandleFunc("/-/ready", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(ready)
		fmt.Fprint(w, "Prometheus Server is Ready.")
	})
	mux.Handle("/", promHandler(answers))
	return fakeServices{"prometheus/prometheus:9090": mux}
}

func TestPromReady(t *testing.T) {
	ctx := context.Background()
	expect(t, (&PromReady{}).Run(ctx, newEnv(t, app, nil, promSvc(200, nil))), gate.Pass)
	r := (&PromReady{}).Run(ctx, newEnv(t, app, nil, promSvc(503, nil)))
	expect(t, r, gate.Pending)
	if r.Query == "" {
		t.Error("missing query")
	}
	expect(t, (&PromReady{}).Run(ctx, newEnv(t, app, nil, fakeServices{})), gate.Pending)
}

func TestPromCanaryScraped(t *testing.T) {
	sel := `up{namespace="canary",job="kubernetes-pods",app_kubernetes_io_name="podinfo"}`
	sum := fmt.Sprintf("sum_over_time(%s%s)", sel, promWin)
	lbl := map[string]string{"job": "kubernetes-pods"}
	tests := []struct {
		name    string
		hr      runtime.Object
		answers map[string][]Sample
		want    gate.Status
		in      string
	}{
		{"pass", promHR("True"), map[string][]Sample{sel: {{lbl, 1}}, sum: {{lbl, 5}}}, gate.Pass, "5 scrapes, up=1"},
		{"too few scrapes", promHR("True"), map[string][]Sample{sel: {{lbl, 1}}, sum: {{lbl, 2}}}, gate.Pending, "2/3 scrapes since Ready"},
		{"not discovered", promHR("True"), nil, gate.Pending, "canary target not discovered"},
		{"down", promHR("True"), map[string][]Sample{sel: {{lbl, 0}}, sum: {{lbl, 5}}}, gate.Pending, "down"},
		{"hr not ready", promHR("False"), nil, gate.Pending, "not Ready"},
		{"no hr", nil, nil, gate.Pending, "helmrelease"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var objs []runtime.Object
			if tc.hr != nil {
				objs = append(objs, tc.hr)
			}
			r := (&PromCanaryScraped{}).Run(context.Background(), newEnv(t, app, objs, promSvc(200, tc.answers)))
			expect(t, r, tc.want)
			if !strings.Contains(r.Value+r.Reason, tc.in) {
				t.Errorf("want %q in value/reason, got value=%q reason=%q", tc.in, r.Value, r.Reason)
			}
			if r.Status == gate.Pass && r.Query != sum {
				t.Errorf("query = %q", r.Query)
			}
		})
	}
}

func TestPromWindowMinimum(t *testing.T) {
	env := newEnv(t, app, []runtime.Object{promHR("True")}, nil, func(e *gate.Env) {
		e.Now = func() time.Time { return time.Date(2026, 11, 8, 11, 50, 10, 500, time.UTC) }
	})
	win, _, ok := promWindow(context.Background(), env)
	if !ok || win != "[60s]" {
		t.Fatalf("win = %q ok=%v", win, ok)
	}
	env.Now = func() time.Time { return time.Date(2026, 11, 8, 12, 4, 5, 1, time.UTC) }
	if win, _, _ := promWindow(context.Background(), env); win != "[846s]" {
		t.Fatalf("win = %q", win)
	}
}

func TestPromTargetsUp(t *testing.T) {
	ctx := context.Background()
	r := (&PromTargetsUp{}).Run(ctx, newEnv(t, app, nil, promSvc(200, map[string][]Sample{"count(up)": {{nil, 12}}})))
	expect(t, r, gate.Pass)
	if r.Value != "12 targets up" {
		t.Errorf("value = %q", r.Value)
	}
	r = (&PromTargetsUp{}).Run(ctx, newEnv(t, app, nil, promSvc(200, map[string][]Sample{
		"count(up == 0)": {{nil, 2}},
		"up == 0":        {{map[string]string{"job": "kubelet"}, 0}, {map[string]string{"job": "coredns"}, 0}},
	})))
	expect(t, r, gate.Pending)
	if !strings.Contains(r.Reason, "coredns, kubelet") {
		t.Errorf("reason = %q", r.Reason)
	}
	expect(t, (&PromTargetsUp{}).Run(ctx, newEnv(t, app, nil, promSvc(200, nil))), gate.Pending)
}

func TestPromRuleEvalFailures(t *testing.T) {
	q := "sum(increase(prometheus_rule_evaluation_failures_total" + promWin + "))"
	objs := []runtime.Object{promHR("True")}
	ctx := context.Background()
	expect(t, (&PromRuleEvalFailures{}).Run(ctx, newEnv(t, app, objs, promSvc(200, nil))), gate.Pass)
	expect(t, (&PromRuleEvalFailures{}).Run(ctx, newEnv(t, app, objs, promSvc(200, map[string][]Sample{q: {{nil, 0}}}))), gate.Pass)
	r := (&PromRuleEvalFailures{}).Run(ctx, newEnv(t, app, objs, promSvc(200, map[string][]Sample{q: {{nil, 3}}})))
	expect(t, r, gate.Fail)
	if r.Query != q {
		t.Errorf("query = %q", r.Query)
	}
	expect(t, (&PromRuleEvalFailures{}).Run(ctx, newEnv(t, app, nil, promSvc(200, nil))), gate.Pending)
}

func TestPrometheusRegistered(t *testing.T) {
	f, ok := Sets["prometheus"]
	if !ok || len(f()) != 4 {
		t.Fatal("prometheus check set not registered with 4 checks")
	}
}
