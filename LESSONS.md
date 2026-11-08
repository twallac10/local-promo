# Lessons learned: evidence-gated promotion demo

_Snapshot of 2026-11-08. The live, editable version is the Claude doc [Lessons learned: evidence-gated promotion demo](https://claude.ai/artifact/RQ2Lb58jswWTd3HwrLEUzB)._

## Summary

The design held up on its first live run; the stack around it did not. Every app's evidence gate passed in dev and prd and promoted dev → stg, but getting there took 17 fixes, almost all found only on a real cluster on an Apple Silicon laptop.

The demo: platform apps (Kyverno, kyverno-policies, guardrails, kube-prometheus-stack, OTel Collector) promote through three kind clusters (dev → stg → prd). Each promotion is a PR that copies one `release.yaml`; it merges only when the source tier's own in-cluster operator has recorded evidence on GitHub that this exact release works there. prd waits for environment approval.

The three takeaways for the next demo:

1. **Budget the laptop first.** Three kind clusters with this stack overloaded 6 CPUs and 12 GiB; etcd disk stalls caused restart storms. Decide the cluster count and footprint before writing manifests.
2. **Static checks are not enough.** Lint and unit tests passed throughout; 15 of the 17 failures were things only a running cluster or the real image reveals (CPU architecture, chart name, label rules, runtime components, CRD validation). Test against real images early.
3. **Run one tier end to end before building all of them.** Most failures repeated identically in every tier; one healthy cluster would have surfaced them at a third of the cost.

## What broke on the first live run

In the order they surfaced, from a fresh clone on an 8-core Apple Silicon Mac to dev and prd fully green. "Now caught by" is what stops it recurring.

| # | Symptom | Root cause | Fix | Now caught by |
| --- | --- | --- | --- | --- |
| 1 | `task lint` failed on a fresh clone: no schema for PromotionGate | The schema cache (24 MB) had been committed before the repo had a `.gitignore` | Untracked it; cache rebuilds when its inputs change | Hash-stamped cache |
| 2 | `task tools` said PyYAML missing after `pip install` | `pip` and `python3` were different Homebrew Pythons | Dropped PyYAML; YAML goes through `yq` | Nothing needed |
| 3 | Promoter image build failed | Dockerfile copied named dirs and missed the new `api/` package | `COPY . .` with `.dockerignore` | `ci` workflow builds the image on every push |
| 4 | `flux bootstrap`: unknown flag `--silent` | Flag removed in Flux 2.10 | Dropped it | Flags checked against the installed CLI |
| 5 | guardrails install failed: invalid label value | Flux installs OCI charts as `0.1.0+<digest>`; the chart put the version in a label | Replace `+` with `_` (guardrails 0.1.1) | Lint renders local charts with a `+build` version and checks label values |
| 6 | otel digest changed on every seed | Chart publishes as `opentelemetry-collector`; config said `otel-collector` | Renamed everywhere | Mirror script and lint fail on name mismatch |
| 7 | Gates failed for apps still waiting on a dependency | Operator treated `DependencyNotReady` as "stuck" | Waiting stays Waiting | Unit test |
| 8 | kyverno gates failed during bootstrap | Checks used the canary namespace, which installs last | Dry-runs in the promoter namespace; canary coming up re-triggers gates | Unit tests |
| 9 | Kyverno webhook "connection refused" blocked all applies | Docker VM had 7.75 GiB; Kyverno crash-looped | Docker 12 GiB; Kyverno cleanup controller off | Memory guidance in NOTES.md |
| 10 | Gates stuck "stale in\_progress" for 15 min | Operator restart orphaned running gates | Re-run at once when not owned by this process | Unit test |
| 11 | guardrails and kyverno-policies failed "helm tests" | Charts without tests report success with no hooks | Treated as skip | Unit test |
| 12 | kube-prometheus-stack never Ready (ImagePullBackOff) | prometheus-operator v0.95.1 published amd64-only | Chart 92.21.2 with operator v0.94.2 | `task images:check` (amd64 + arm64) |
| 13 | Gate errors: GitHub "unexpected EOF" | Dropped connections under CPU load | Retry GET/HEAD 3× with backoff | Unit test |
| 14 | Grafana crash loop, log stops mid-startup | 256 MiB limit; Grafana 13 OOM-killed while starting | 1 GiB limit, liveness waits 300 s | Not caught statically |
| 15 | OTel Collector crash: unknown exporter `prometheus` | The `-k8s` distribution doesn't include it | Removed (unused) | Lint runs the real image's `validate` |
| 16 | Two PromotionGates showed no status | CRD required `startTime`; runs mirrored from GitHub had none | Field made optional | Test checks CRD required fields |
| 17 | Idle clusters at \~1.8 cores each; restarts every few minutes | etcd fsync stalls on the shared Docker disk | etcd on tmpfs; clusters built one at a time | Unverified (see open items) |

## Lessons: the local runtime

The laptop was the hardest constraint, and it was discovered last. Size it before anything else.

- **Measure one cluster, then multiply.** One kind cluster with this stack used 2.2–2.9 GiB and, at idle, about 1.8 cores. Three of them on a 6-CPU, 12 GiB Docker VM left no headroom; the 7.75 GiB default was not enough to install at all.
- **Kubernetes failures under load look like app bugs.** A starved control plane shows up as webhook "connection refused", Helm timeouts, crash loops and leader-election restarts across unrelated components. Check `docker stats` and restart counts before debugging an app.
- **Fail-closed admission webhooks amplify overload.** When Kyverno's admission controller fell over, every create or update it covered was refused, including Flux's own components. Webhook-based policy is the first thing to break and takes everything with it.
- **etcd on a shared VM disk is a known kind trap.** fsync stalls froze the API servers and every leader-elected component restarted together, 27–44 times in 6 hours. Putting etcd on the node's tmpfs is the standard fix; cluster state then dies with Docker.
- **Bootstrap one cluster at a time.** Three clusters installing CRDs and Grafana at once starved each other. `task up` now waits for each tier to be Ready; `task up -- dev` builds one tier.
- **Check every image for both CPU architectures.** Apple Silicon kind nodes need arm64. One upstream release (prometheus-operator v0.95.1) shipped amd64-only and blocked the whole stack. Single-arch images of your own run under emulation, slower. `task images:check` now checks both.
- **Don't give Docker every core.** 6 of 8 cores was the most the user would give; design for that, not for the machine's total.

## Lessons: charts, Flux and the gate logic

- **Flux changes the chart version you render.** OCI charts install as `<version>+<digest>`; anything that puts the version in a label breaks. Render your own charts with a build suffix in lint.
- **`helm push` decides the published name, not your config.** It always uses the chart's own name. A mismatch silently re-publishes (new digest every time) and points clusters at a name that doesn't exist.
- **Know which components your image contains.** Distribution images (the OTel Collector `-k8s` build) omit components a chart's examples use. Validate the rendered config with the pinned image itself.
- **Resource limits written for "lightweight" need a real start.** Grafana 13 needs more than 256 MiB just to start; an OOM kill leaves a log that simply stops. Look at `lastState.terminated.reason` first.
- **Gates must expect bootstrap.** The canary installs after every app, so canary-dependent checks can't pass the first time. Make the gate wait for, or re-run on, what it depends on rather than fail.
- **"No tests" is an answer.** Flux reports `TestSuccess=True` with no hooks for charts without tests; treat that as skip, not as "not run yet".
- **CRD required fields must match every code path.** One path (status mirrored from GitHub) left a required field empty, and the API server silently rejected every status update. Test the CRD schema against what each path writes.
- **A release is the whole release file, not the chart digest.** Keyed on the digest, a values-only change (the ready-but-broken scenario) would never be re-gated and could be promoted on old evidence. Key evidence on the commit that last changed the tier's `release.yaml`.
- **Operators restart; in-flight work gets orphaned.** Anything left in progress by a previous process should be re-run promptly, not after a long stale timeout.

## Lessons: process and tooling

- **Build where it will run, early.** Phases 0–5 were written and statically validated in a cloud container that could not run kind. Every phase "passed" there. A real cluster on the target laptop after Phase 1 would have caught most of the table above before Phases 2–5 were built on top.
- **Know what each check proves.** kubeconform validates schemas, not label formats or registry contents; `helm template` doesn't know which components an image has; a fake API client doesn't run CRD validation. Every lint and test we later added closes one of those gaps (labels, names, architectures, collector config, CRD fields).
- **Check what you commit.** A cache directory went into the first commit because `.gitignore` was added afterwards. Add `.gitignore` before the first `git add`.
- **The demo runs on a Mac; test like one.** macOS ships bash 3.2 (empty arrays under `set -u` fail), Homebrew splits `pip` from `python3`, and `sha256sum` may be missing. Prefer tools the demo already requires (`yq`, `jq`) over language packages.
- **Never move a release tag.** The promoter went v0.1.0 → v0.1.7 during the run. Bumping the version in one place (`VERSION`) with lint checking every pin kept app repos, CI and clusters consistent.
- **Debug by asking for one precise command.** The fastest fixes came from targeted output: the full condition message, `ps` inside the node, `docker manifest inspect`, the pod's last termination reason. Truncated status lines hid the cause every time; `task status` now flattens messages instead.
- **Verify delegated work.** Subagents wrote the per-app values, checks and manifests. Several of the live failures (chart name, collector exporter, Grafana limit, image tag choice) came from plausible-looking work that was validated statically but never run. Treat generated config like untested code.

## Should the next demo use different apps?

Yes, if the point is the promotion mechanics rather than these specific platform apps. Two of the five apps carried most of the cost and most of the breakage, and lighter stand-ins show the same things.

**Decision:** this demo and the next one use plain Prometheus (one server, no operator, no Grafana) instead of kube-prometheus-stack, and keep Kyverno, since its policies are the interesting part. Kyverno runs with only its admission and reports controllers. The Grafana gate checks and `task grafana` are gone; `task prometheus -- <tier>` opens the Prometheus UI instead.

| App | What it demonstrated | What it cost | Lighter alternative |
| --- | --- | --- | --- |
| Kyverno (+ policies, guardrails) | Policy enforcement; Audit vs Enforce as tier config; dry-run admission checks | 2–4 controllers; \~0.3 core per cluster at idle (reports + admission); its fail-closed webhook took every apply down when it fell over | Built-in Kubernetes: Pod Security Admission (namespace labels, `warn` vs `enforce` per tier) and ValidatingAdmissionPolicy for the OCI-only guardrails. Runs in the API server: no pods, no webhook to fail |
| kube-prometheus-stack | The key "Ready ≠ working" scenario (canary scrape), rule evaluation, Grafana dashboard query | Largest install (big CRDs, operator, Prometheus, Grafana); the arm64 image gap; Grafana OOM; slow Helm installs | Plain Prometheus chart (no operator) or VictoriaMetrics single-node; Grafana optional. A scrape-config change still demonstrates Ready ≠ working |
| OTel Collector | Telemetry acceptance check (spans accepted, no export failures) | Small (64 MiB) once the image/config mismatch was fixed | Keep |
| podinfo canary + loadgen | The thing every gate measures | Tiny | Keep |

Two further options:

- **Add one tiny promoted app** (podinfo itself in its own app repo). It reconciles in seconds, so promotions and the three scenarios run fast, and it is easy to break on purpose (a value that makes `/readyz` fail while the pod stays Running).
- **Keep the real apps only if realism is the goal.** If the audience needs to see Kyverno and kube-prometheus-stack specifically, run two tiers locally (dev + prd still shows promotion and approval) or use a bigger machine.

## Pre-flight checklist for the next demo

Before writing manifests:

- [ ] Write down the machine: CPU architecture, cores and memory you will give Docker (here: arm64, 6 of 8 cores, 12 GiB).
- [ ] Decide the cluster count from that budget, assuming \~2.5 GiB and \~1 core per cluster for a stack like this one.
- [ ] Pick the apps for what they demonstrate, with the lightest stand-in that still shows it (see above).
- [ ] Check every image you plan to pin has amd64 and arm64 builds (`docker manifest inspect`).
- [ ] Add `.gitignore` before the first commit.

Before building on top of the platform:

- [ ] Stand up one tier on the target laptop and get every app Ready and stable for 30 minutes (restart counts at 0).
- [ ] Record idle CPU and memory for that cluster; only then add the next tier.
- [ ] Use etcd on tmpfs and build clusters one at a time.
- [ ] Run each chart's real image where it has a config validator (OTel `validate`, Prometheus `promtool`).
- [ ] Render your own charts the way Flux will (version with `+build` suffix) and check label values.
- [ ] Confirm the published chart name matches what the clusters pull.

Before the demo:

- [ ] Run each scenario once from a fresh `task up`, then `task demo:reset` between scenarios.
- [ ] Decide who approves prd: a second GitHub account for the promoter token, or prevent-self-review off.
- [ ] Make every GHCR package public (charts and the promoter image) and confirm anonymous pulls work.

## Still open

The promotion chain itself has not yet been exercised end to end with a real change; only the bootstrap state passed.

- etcd on tmpfs: does it stop the restarts and bring idle CPU well under 1 core per cluster? Not yet measured.
- stg was still bootstrapping at the last status; all three tiers green at once is unconfirmed.
- None of the three scenarios (`demo:good`, `demo:ready-but-broken`, `demo:sneaky`) has run yet.
- Whether GitHub applies environment protection (prd reviewers, branch policy) to the promoter's own API-created Deployments.
- Approval with prevent-self-review: needs a second account, or the setting off.
- Phase 6 (chart signing with cosign) not started.

Project notes, decisions and the full fix history: `platform-fleet/NOTES.md` and the commit log on branch `claude/new-session-5t8rkg` of `twallac10/local-promo`.
