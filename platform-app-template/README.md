# __APP__

Deployment repo for the `__APP__` platform app. Created from
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
platform-fleet `fleet/apps/__APP__.yaml`).

## Changing things

- **New chart version**: bump `version` in `mirror/chart.yaml`. Nothing else.
- **Shared setting**: edit the first tier's `release.yaml`; it flows from there.
- **Tier setting**: edit that tier's `tier.yaml`. It never leaves the tier.
