# Canary

A small, never-promoted workload (`podinfo` + `loadgen`, namespace `canary`) that is identical
in every tier. The fleet applies `./canary` once all platform apps are Ready. It exists so promotion
gates have something real to check.

| Platform app | What the canary proves |
|---|---|
| Kyverno / Pod Security | podinfo and loadgen are admitted under baseline Enforce (and are restricted-compliant) |
| kube-prometheus-stack | ServiceMonitor `canary/podinfo` is scraped: `up{namespace="canary",service="podinfo"} == 1` (job `podinfo`) |
| OpenTelemetry Collector | podinfo exports OTLP gRPC traces/logs to `otel-collector.otel.svc.cluster.local:4317` (service name `canary-podinfo`) |
| Flux | HelmRelease `canary/podinfo` Ready, `helm test` passes |

`loadgen` curls podinfo every ~2s so request metrics (`http_request_duration_seconds_count`) and traces keep flowing.

The chart digest in `ocirepository.yaml` is a placeholder set by `task charts:seed`; the chart is mirrored via `mirror/chart.yaml`.

## Check by hand

```sh
flux get hr -n canary podinfo
kubectl -n canary get pods,servicemonitor
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090 &
curl -s 'localhost:9090/api/v1/query?query=up{namespace="canary",service="podinfo"}'
kubectl -n canary logs deploy/podinfo | head          # no OTLP export errors
kubectl -n otel logs deploy/otel-collector | grep canary-podinfo
```
