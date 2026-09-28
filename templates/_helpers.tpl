{{/*
Expand the name of the chart.
*/}}
{{- define "nemo-guardrails.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. Truncated at 63 chars for DNS-1123 label limits.
*/}}
{{- define "nemo-guardrails.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "nemo-guardrails.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "nemo-guardrails.labels" -}}
helm.sh/chart: {{ include "nemo-guardrails.chart" . }}
{{ include "nemo-guardrails.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: nemo-guardrails
{{- end }}

{{- define "nemo-guardrails.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nemo-guardrails.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "nemo-guardrails.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "nemo-guardrails.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name of the Secret holding upstream provider API keys.
*/}}
{{- define "nemo-guardrails.secretName" -}}
{{- if .Values.existingSecret }}
{{- .Values.existingSecret }}
{{- else }}
{{- printf "%s-model-keys" (include "nemo-guardrails.fullname" .) }}
{{- end }}
{{- end }}

{{/*
ConfigMap name for a single guardrails configuration.
Call with a dict: (dict "root" $ "id" $configId)
*/}}
{{- define "nemo-guardrails.configMapName" -}}
{{- printf "%s-config-%s" (include "nemo-guardrails.fullname" .root) .id | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Server command-line arguments assembled from .Values.server.
*/}}
{{- define "nemo-guardrails.serverArgs" -}}
{{- $args := list "server" "--port" (printf "%v" .Values.server.port) "--config" .Values.server.configPath -}}
{{- if .Values.server.disableChatUi }}{{- $args = append $args "--disable-chat-ui" }}{{- end }}
{{- if .Values.server.verbose }}{{- $args = append $args "--verbose" }}{{- end }}
{{- if .Values.server.autoReload }}{{- $args = append $args "--auto-reload" }}{{- end }}
{{- if .Values.server.defaultConfigId }}{{- $args = append $args "--default-config-id" }}{{- $args = append $args .Values.server.defaultConfigId }}{{- end }}
{{- range .Values.server.extraArgs }}{{- $args = append $args . }}{{- end }}
{{- toYaml $args }}
{{- end }}
