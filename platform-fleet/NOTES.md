# Notes

Running notes for the evidence-gated promotion demo. Status: Phases 0–5 written;
0–1 statically validated, 2–4 unit-tested against fakes, 5 scripted; nothing run on live
clusters or real GitHub yet.

## Decisions

| Decision | Choice |
|---|---|
| Owner / prefix | `twallac10`, `platform-` |
| Tiers | `dev` → `stg` → `prd`; only `prd` requires approval |
| kyverno-policies | Its own app repo |
| Guardrails | **Promoted app** (`platform-guardrails`): a chart built from source in that repo, mirrored to GHCR and promoted by digest like the others, so new or changed guard policies are proven in dev before prd |
| Signing (Phase 6) | Wanted, nice to have; after Phase 5 |
| Gate thresholds | ≥ 3 successful canary scrapes since Ready; counters compared over ≥ 30 s; each check waits ≤ 5 min for data |

## Layout

The repos are developed as one workspace (folders named after the repos) and
pushed to separate GitHub repos by `task repos:create` / `task repos:push`.
App repos are created from `platform-app-template`; `task repos:shape` (part of
`task lint`) fails if an app repo's file set or shared files drift from it.

## Release vs tier config

- `tiers/<tier>/release.yaml` is the only promotable thing: the
  `OCIRepository` digest (with the semver as an annotation) and the HelmRelease
  values every tier shares, including explicit image tags.
- `tiers/<tier>/tier.yaml` is a `HelmRelease` patch with `spec.values` only.
- `validate.sh` enforces this: `release.yaml` may hold only those two docs and
  the OCIRepository part only `ref.digest`; `tier.yaml` may only set values, so
  it can never move a chart digest or a source URL.
- Values are merged by Kustomize strategic merge on the HelmRelease, so maps
  deep-merge; lists are replaced. Don't put the same list in both files.

## OCI only

- Charts come only from `oci://ghcr.io/twallac10/charts/<name>` via
  `OCIRepository` (layerSelector `application/vnd.cncf.helm.chart.content.v1.tar+gzip`)
  and `HelmRelease.spec.chartRef`. Flux v2.10.0 (OCIRepository `v1`, HelmRelease `v2`).
- `platform-guardrails` denies any `HelmRepository` and any `OCIRepository`
  outside the prefix (Kyverno CEL `ValidatingPolicy`, `policies.kyverno.io/v1`,
  `Deny`). Verified with the Kyverno v1.19.2 CLI: HelmRepository, a docker.io
  OCIRepository and a lookalike `ghcr.io/twallac10-evil/...` are denied; ours passes.
- Guardrails are installed after kyverno and before anything else that pulls a
  chart, so they cover every other app. They cannot cover kyverno itself (it
  installs them); `validate.sh` and the CI guardrail (Phase 3) cover that gap.
- `mirror-chart.sh` never re-pushes an existing version, because a re-push
  mints a new digest. A new upstream version means a new `mirror/chart.yaml`.
- **GHCR visibility:** packages pushed from a laptop start private and GitHub
  has no API to change that. After the first `task charts:seed`, open
  `https://github.com/users/twallac10/packages`, and for each `charts/<name>`
  set Package settings → Change visibility → Public. Packages first pushed by
  a repo's Actions workflow may inherit that repo's visibility; check once.

## Bootstrap exceptions

- `task charts:seed` points **every** tier at the first digest so `task up` can
  reach Ready. That is the only time a digest enters a tier other than the
  first without a promotion PR.
- The mirror workflow opens the entry PR with `PROMOTER_TOKEN`, because PRs
  opened with `GITHUB_TOKEN` don't trigger other workflows (the guardrails).

## Kyverno policy mode

- `kyverno-policies` 3.9.2 defaults to CEL `ValidatingPolicy`
  (`policies.kyverno.io/v1beta1`). `validationFailureAction` (tier.yaml)
  renders to `validationActions: [Audit]` in dev/stg and `[Deny]` in prd.
- `vpolExclude.excludeNamespaces: [kube-system, local-path-storage]` (the
  `policyExclude` value only applies to legacy ClusterPolicy mode).
- Checked with the Kyverno CLI against the prd policies: the canary (podinfo +
  loadgen) and every kyverno, kube-prometheus-stack and otel-collector
  workload pass; a privileged pod is denied. The Prometheus StatefulSet comes
  from the operator, not the chart, so it was not in that check.
- Gate note for Phase 2: the handoff says "all ClusterPolicies Ready"; with CEL
  policies the check is "all ValidatingPolicies Ready".

## Memory

Estimate per cluster, from requests (to be replaced with measured numbers from
`docker stats` after the first `task up`):

| Component | ~MiB |
|---|---|
| kind node (control plane, etcd, kubelet, CNI) | 700 |
| Flux (4 controllers) | 250 |
| kyverno (4 controllers, 1 replica each) | 400 |
| kube-prometheus-stack (prometheus, grafana, operator, ksm) | 650 |
| otel-collector | 64–256 |
| canary | 50 |
| **total** | **~2.2–2.5 GiB** |

Three clusters ≈ 7–8 GiB. Give Docker **12 GiB**. kind with 3 clusters also
needs higher inotify limits on Linux:
`sudo sysctl fs.inotify.max_user_watches=524288 fs.inotify.max_user_instances=512`.

**Measured:** _TBD after first `task up`._

## Promoter (Phase 2)

- **Evidence storage.** A Deployment's payload is fixed at creation, but the
  outcome is known only at the end. So the full table goes in a commit comment
  on the applied commit, linked as the Deployment status `log_url`, with the
  recorded metrics (e.g. canary PolicyReport failures) in a hidden JSON marker.
  The next run reads its baseline from the last *successful* Deployment's
  comment.
- **One Deployment per (tier, cluster).** The payload names the cluster, and
  `promote` requires every cluster of the source tier to have a `success`
  Deployment for the digest. Locally the CLI checks all of a tier's clusters;
  in-cluster (Phase 4) each attests only itself and whichever finishes last
  opens the PR.
- **Pending vs fail.** "Not enough data yet" (canary not scraped 3 times yet,
  webhook not yet enforcing a fresh policy, second counter sample not due) is
  pending and re-asked; it becomes a failure with the same reason at `maxWait`.
  Things that cannot improve by waiting (HelmRelease `UpgradeFailed`, rule
  evaluation failures, a known-good pod denied) fail immediately.
- **Reads one Secret.** The Grafana datasource/dashboard checks need the admin
  login from `monitoring/grafana`. Everything else is read-only plus
  server-side dry-run creates and Event creates.
- **OTel "from the canary".** Collector self-metrics don't label by client;
  the canary is the only span producer in the demo, so accepted-spans growth is
  attributed to it. In a real fleet use spanmetrics or a per-tenant pipeline.
- **Dashboard check.** The first panels of the chosen kps dashboard rely on
  node-exporter rules we disabled, so the check tries the first few panel
  queries and passes on the first that returns data.

## CI guardrails and environments (Phase 3)

- **One required check:** `promotion / promotion-gate` (caller job `promotion`
  in each app repo's `promotion.yaml`, job `promotion-gate` in the reusable
  workflow in platform-promoter, pinned `@v0.1.1`).
- **Why three jobs instead of one.** Branch protection treats a *skipped* job
  as passing. If `promotion-gate` simply needed the guardrails job and the
  guardrails failed, the gate would be skipped and the PR would auto-merge.
  So `guardrails` verifies, `approval` (promotions only) runs in the target
  tier's environment and pauses for reviewers, and `promotion-gate` always
  runs and fails unless guardrails passed and, for promotions, approval passed.
- **The workflow runs on every PR**, so the required check exists on
  non-promotion PRs too. Those get the OCI-only scan and the secret scan; any
  change to a `tiers/*/release.yaml` is treated as a promotion whatever the
  label says, so release changes can't sneak in as ordinary PRs.
- **Entry PRs** (first tier) have no source tier: the guardrail checks the
  digest exists in GHCR instead.
- **The verifier is Go** (`promoter verify-pr`, unit-tested) built from
  platform-promoter at `promoter-ref`, which must equal the pinned tag
  (`task lint` checks both against `platform-promoter/VERSION`).
  `task repos:push` creates the tag; tags are never moved.
- **Deviation: branch policy is `main` + `promote/*`, not only `main`.** The
  approval job runs on the promotion PR, before merge (merging is what deploys),
  so an environment that only allows `main` would refuse the job. A promote/*
  branch can't deploy anything by itself: it only reaches a cluster by merging,
  which needs the gate.
- **Prevent self-review vs. one person.** The promotion PR (and so the
  workflow run) is triggered by the PROMOTER_TOKEN owner. With prevent
  self-review on, that person can't approve prd. For a real setup use a
  machine account for the promoter; for a one-person demo run
  `PREVENT_SELF_REVIEW=false task gh:envs`.
- **`enforce_admins: false`** so bootstrap (`task repos:push`, `charts:seed`)
  can still push to main directly. Admins can therefore bypass the gate; in a
  real setup turn it on once bootstrapped (and the promoter token must not be
  an admin's).
- **To verify on first run:** that GitHub doesn't apply environment protection
  rules to the promoter's API-created Deployments (environment = tier). If it
  does, move the ledger to `<tier>-gate` environments (one-line change in
  `ledger.StartDeployment` and the verifier).
- Approval and tier.yaml: only promotions need approval. A plain PR changing
  `tiers/prd/tier.yaml` merges with just the OCI/secret checks; in a real
  setup add CODEOWNERS review for tier.yaml.

## In-cluster promoter (Phase 4)

- **An operator.** `promoter serve` is a controller-runtime operator for the
  `PromotionGate` CRD (`platform.twallac10.io/v1alpha1`), deployed by
  platform-fleet to every cluster (`promoter/`). One PromotionGate per app,
  generated from apps.yaml; `kubectl -n promoter get pg` shows each app's
  phase, version and reason in that cluster.
- **Each tier attests for itself.** It checks only its own cluster (in-cluster
  config; it refuses any other cluster name) and talks only to GitHub. Its
  identity comes from the `flux-system/cluster-identity` ConfigMap
  (`CLUSTER_NAME`) that `task up` creates per cluster, because several
  clusters of one tier share `clusters/<tier>/`.
- **Triggers.** It watches each app's Flux Kustomization and HelmRelease
  (filtered to changes in applied revision, attempted config, or readiness)
  and resyncs every gate every 10m. Deviation from the handoff: no Flux
  notification Provider/Alert; watching directly needs no webhook, no shared
  secret, and can't miss events.
- **GitHub is authoritative; status is a mirror.** Decisions come from what
  main declares for the tier and this cluster's latest gate Deployment, so
  restarts are safe and a gate run from the CLI is picked up. The status adds
  per-check results, the evidence URL, the PR and the timing used for retries:
  new digest → gate; failed → retry 2m after Flux applies something new,
  else every 30m; stale `in_progress` → 15m; passed but next tier behind →
  retry the PR every 6h. While Flux isn't Ready it waits, but after 10m stuck
  it gates anyway so the failure is recorded.
- **Long reconciles.** A gate can take up to `maxWait` (5m); it runs inside
  the reconcile, with 4 concurrent reconciles. Fine for a handful of apps;
  for many apps, run gates as Jobs and reconcile on their completion.
- **Read-only RBAC, with one twist.** Server-side dry-run needs `create`
  permission. The promoter has create on pods, HelmRepositories and
  OCIRepositories only for dry-run, and a ValidatingAdmissionPolicy
  (`promoter-dry-run-only`, native CEL, no Kyverno dependency) denies any
  non-dry-run write by its ServiceAccount. Writes otherwise: PromotionGate
  status, Events, its leader-election Lease. Plus `get` on the one Secret
  `monitoring/grafana` (separate Kustomization that waits for
  kube-prometheus-stack).
- **Chicken-and-egg.** The promoter is deployed by platform-fleet directly and
  is **not** gated: it is the thing that produces the evidence, so gating it
  with its own evidence proves nothing, and a broken promoter would block its
  own fix. Its image is pinned by tag to `platform-promoter/VERSION`; its CRD
  is a checked copy of the one platform-promoter generates. Changes go
  through normal review of platform-promoter and platform-fleet. It has no
  dependsOn so it is up before the apps it gates.
- Secret `promoter/promoter-github` (PROMOTER_TOKEN) is created by `task up`,
  never committed. The image package on GHCR must be public, like the charts.

## Demo scenarios (Phase 5)

Run after `task up` (and `task gh:envs`); `task demo:reset` between scenarios
restores every repo to the workspace baseline and closes open promotion PRs.

- `task demo:good`: PR bumping kube-prometheus-stack's `mirror/chart.yaml`
  to 92.22.0 (same operator version as 92.21.2; values validated against it) →
  mirror workflow → dev entry PR (auto-merge) → dev gate → stg PR
  (auto-merge) → stg gate → prd PR waiting for environment approval. The
  script follows each step and stops at the approval.
- `task demo:ready-but-broken`: a shared-value change in dev's release.yaml
  makes Prometheus select only ServiceMonitors labelled
  `platform.twallac10.io/scrape=opt-in`. It renders fine, passes CI (valid,
  same digest), the HelmRelease goes Ready, and the canary target silently
  disappears. The dev gate waits for canary scrapes, fails at `maxWait` with
  "canary target not discovered", records a failed Deployment and a
  `PromotionGateFailed` Event, and no stg PR is opened. Takes about maxWait
  (5m) after Flux applies it.
- `task demo:sneaky`: a `promote/stg/*` PR (labelled `promotion`) that copies
  dev's release.yaml and also sets `validationFailureAction: Enforce` in
  `tiers/stg/tier.yaml`. `promotion / promotion-gate` fails ("only
  tiers/<target>/release.yaml changed") and the PR never merges.
- **Bug found while writing these: a release is the whole release.yaml, not
  just the digest.** ready-but-broken changes values only, so the digest is
  the same; keyed on the digest alone, the operator wouldn't re-gate and CI
  would accept promoting new values on old evidence. Gate Deployments now
  record the commit that last changed the tier's release.yaml; the operator
  re-gates when it changes, and `promote`/CI require the source tier's success
  for that exact commit (CI: "gated release commit … not gated yet").

## Architectures (first live run, Apple Silicon)

- prometheus-operator / prometheus-config-reloader **v0.95.1** were published
  amd64-only, so kube-prometheus-stack 93.x never became Ready on arm64
  (`no match for platform in manifest`). Baseline is now chart **92.21.2**
  with operator **v0.94.2** (multi-arch); `demo:good` bumps to 92.22.0
  (same operator). `task images:check` renders everything and fails on any
  image without both linux/amd64 and linux/arm64.
- The promoter image is built for linux/amd64 and linux/arm64 (buildx,
  cross-compiled Go; no emulation).
- Grafana 13 is OOM-killed during startup with a 256Mi limit (log just stops
  mid-startup). Now 256Mi request / 1Gi limit; liveness waits 300s for its
  first-start migration. prometheus-operator limit 256Mi.
- The `otel/opentelemetry-collector-k8s` distribution has no `prometheus`
  exporter; the collector refused to start. Dropped it (the canary sends
  traces and logs only; gates read the collector's own :8888 metrics).
  `task lint` now runs the pinned collector image's `validate` on each tier's
  rendered config when docker is available.
- Steady state still cost ~1.8 cores per cluster, and every leader-elected
  component (kube-controller-manager, scheduler, Flux, Kyverno) restarted
  together every few minutes: etcd fsyncs on the shared Docker Desktop disk
  stalled the API server. etcd now runs on the node's tmpfs (`kind/cluster.yaml`);
  cluster state is lost on a Docker restart (`task down && task up`).
- Three clusters bootstrapping at once starved the API servers on 6 CPUs
  (leader-election restarts everywhere). `task up` now builds tiers one at a
  time, and `task up -- dev` builds a single tier.

## Trust assumptions

- The promoter's token (fine-grained, app repos only: contents, pull requests,
  deployments write) is the only identity that writes Deployment statuses. CI
  trusts a `success` Deployment as evidence; anyone else with deployments write
  on an app repo could forge it. (Phase 2–3.)
- The promoter is deployed by platform-fleet and is **not** itself gated
  (chicken-and-egg: the thing that produces evidence can't be promoted by its
  own evidence). Changes to it are reviewed normally. (Phase 4.)

## What would differ in a real ~20-cluster AKS setup

- ACR instead of GHCR; private, pulled with workload identity, not public packages.
- Each tier is several clusters; the gate must pass on all before tier N+1's PR
  (the promoter in each cluster attests; something must aggregate per tier).
- Flux bootstrap via the AKS Flux extension or Terraform, not `flux bootstrap github`.
- GitHub App instead of PATs for the promoter and Flux.
- Real alerting (Alertmanager HA), node-exporter, longer retention.
