{{- define "guardrails.labels" -}}
app.kubernetes.io/name: guardrails
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- /* Flux appends the OCI digest as build metadata (0.1.1+abc123); '+' is
     not allowed in label values, so replace it like upstream charts do. */}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" | quote }}
{{- end -}}
