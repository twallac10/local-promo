# platform-fleet

Fleet config for the evidence-gated promotion demo: which tiers exist, which
platform apps run in them, and how each tier's kind cluster is wired to the app
repos through Flux.

| Path | What |
|---|---|
| `tiers.yaml` | The promotion chain. A tier is a list of clusters (kube contexts). |
| `apps.yaml` | Each platform app, its repo, namespace and Flux dependencies. |
| `clusters/<tier>/` | Flux bootstrap output (`flux-system/`) plus `platform.yaml`, the root Kustomization for `./fleet` with `TIER=<tier>`. Generated. |
| `fleet/` | One `GitRepository` + `Kustomization` per app (path `./tiers/${TIER}` in the app repo), plus the canary. Generated. |
| `canary/` | podinfo + a load generator, identical in every tier, never promoted. Gates check the platform through it. |
| `kind/` | Cluster config shared by every tier. |
| `scripts/` | Everything the Taskfile runs. |
| `NOTES.md` | Design notes, trust assumptions, sizing, what differs in a real AKS fleet. |

Repos: [platform-app-template](https://github.com/twallac10/platform-app-template),
platform-kyverno, platform-kyverno-policies, platform-guardrails,
platform-kube-prometheus-stack, platform-otel-collector, platform-promoter.

## Prereqs

docker (≥ 12 GiB memory for the engine, see NOTES.md), kind v0.31.0, kubectl,
flux v2.10.0, helm v3.16+, gh (authenticated), jq, task, yq v4 (mikefarah), kustomize,
kubeconform, python3 (standard library only), rsync, go.

Tokens (separate, least privilege, never committed):

- `GITHUB_TOKEN` for `task up`: Flux bootstrap of platform-fleet only
  (fine-grained: contents + administration write on platform-fleet).
- `GHCR_TOKEN` for `task charts:seed`: classic token with `write:packages`
  (or `gh auth refresh -s write:packages` and leave it unset).
- `PROMOTER_TOKEN` Actions secret in each app repo (Phase 2+): fine-grained,
  app repos only, contents + pull requests + deployments write.

## First run

```sh
task tools            # check CLIs
task lint             # static checks, no cluster
task repos:create     # create repos on GitHub and push this workspace
task charts:seed      # mirror charts to GHCR, pin every tier to the digests
#   -> make the GHCR packages public (one time, see NOTES.md)
task repos:push       # commit the digests, tag platform-promoter (VERSION)
PROMOTER_TOKEN=... task gh:envs   # environments, branch protection, auto-merge, secret
GITHUB_TOKEN=... PROMOTER_TOKEN=... task up   # kind clusters, Flux bootstrap, promoter Secret per cluster
task status
task grafana -- dev
task check -- --app kyverno --tier dev        # evidence table + dev Deployment
task promote -- --app kyverno --from dev      # gate dev, open the stg PR (auto-merges)
task down
```

## Demo scenarios

```sh
task demo:good               # chart bump flows dev -> stg -> prd PR awaiting approval
task demo:reset
task demo:ready-but-broken   # HelmRelease Ready, gate blocks it in dev: canary not scraped
task demo:reset
task demo:sneaky             # promotion PR that also changes tier.yaml: CI rejects it
```

Each runs on top of `task up` (see NOTES.md for what each shows).

## Adding a tier or an app

- Tier: add it to `tiers.yaml`, `task fleet:render`, add `tiers/<tier>/` to
  each app repo (copy `release.yaml` from the previous tier, write `tier.yaml`).
- App: add it to `apps.yaml`, create its folder from the template, `task fleet:render`,
  `task repos:create`.
