# guardrails chart

Kyverno CEL `ValidatingPolicy` (`policies.kyverno.io/v1`, served by Kyverno 3.9.2 CRDs) guardrails for Flux sources.

| Policy | Effect |
|---|---|
| `deny-helmrepository` | Denies CREATE/UPDATE of `source.toolkit.fluxcd.io` `HelmRepository` (any version) |
| `restrict-ocirepository-url` | Denies `OCIRepository` whose `spec.url` does not start with `allowedOCIPrefix` |

| Value | Default |
|---|---|
| `validationActions` | `[Deny]` (tiers may set `[Audit]`) |
| `allowedOCIPrefix` | `oci://ghcr.io/twallac10/charts/` |

## Example manifests (for manual testing)

Denied:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata: {name: bad, namespace: default}
spec: {url: https://charts.example.com, interval: 1h}
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata: {name: bad, namespace: default}
spec: {url: oci://docker.io/library/evil, interval: 1h, ref: {tag: latest}}
```

Admitted:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata: {name: ok, namespace: default}
spec: {url: oci://ghcr.io/twallac10/charts/podinfo, interval: 1h, ref: {tag: 1.0.0}}
```
