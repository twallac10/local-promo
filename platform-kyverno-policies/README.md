# kyverno-policies

Deployment repo for the `kyverno-policies` platform app. Created from
[platform-app-template](https://github.com/twallac10/platform-app-template) by
`task repos:create` in platform-fleet; keep the shape identical to the template.

| Path | What | Promoted? |
|---|---|---|
| `base/` | Namespace, `OCIRepository` (GHCR, OCI only) and `HelmRelease` (`chartRef`) | n/a |
| `tiers/<tier>/release.yaml` | Chart digest, image tags, values shared by every tier | **yes**: copied verbatim from tier N-1 |
| `tiers/<tier>/tier.yaml` | Replicas, retention, hostnames, enforcement mode | **never** |
| `mirror/chart.yaml` | Upstream chart and pinned version | bump to start a promotion |
| `.github/workflows/mirror.yaml` | Mirrors the chart to GHCR, opens the first-tier PR | |
| `scripts/` | Used by the workflows and by `task charts:seed` | |

Flux in each tier's cluster applies `./tiers/<tier>` from this repo (see
platform-fleet `fleet/apps/kyverno-policies.yaml`).

## Changing things

- **New chart version**: bump `version` in `mirror/chart.yaml`. Nothing else.
- **Shared setting**: edit the first tier's `release.yaml`; it flows from there.
- **Tier setting**: edit that tier's `tier.yaml`. It never leaves the tier.

## kyverno-policies specifics

Chart `kyverno-policies` 3.9.2 (upstream https://kyverno.github.io/kyverno), `policyType: ValidatingPolicy`
(CEL, `policies.kyverno.io/v1beta1` as rendered by this chart version), Pod Security Standard `baseline` (11 policies).
The chart has no images and no Helm tests.

- **Enforcement is tier-only**: `validationFailureAction` is `Audit` in dev/stg and `Enforce` in prd. For
  ValidatingPolicy the chart maps it to `spec.validationActions`: `Audit` renders `[Audit]`, `Enforce` renders `[Deny]`
  (verified with `helm template`; all 11 policies in each case).
- **Exclusions are shared** (release.yaml): `vpolExclude.excludeNamespaces: [kube-system, local-path-storage]`. The chart
  excludes nothing by default. `policyExclude` only applies to legacy `ClusterPolicy`; for ValidatingPolicy the value is
  `vpolExclude` / `vpolExcludeByPolicy`, which renders a CEL matchCondition
  `!(request.namespace in ['kube-system', 'local-path-storage'])` on each policy.
- Why: kind's kube-proxy and kindnet (kube-system, hostNetwork/privileged/hostPath) and local-path-provisioner
  (local-path-storage) would be denied by baseline on restart in prd. Existing pods are not re-admitted, but restarts
  and rollouts are. kube-prometheus-stack runs with node-exporter disabled, so it needs no exclusion.
- Policies only match Pods (CREATE/UPDATE) and `validationAllowExistingViolations: true` keeps existing objects admissible.
