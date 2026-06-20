{{/*
Common helpers for the Delta-V chart.
*/}}

{{/* Chart name, overridable. */}}
{{- define "deltav.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully-qualified release name. */}}
{{- define "deltav.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "deltav.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels. */}}
{{- define "deltav.labels" -}}
helm.sh/chart: {{ include "deltav.chart" . }}
{{ include "deltav.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: deltav
{{- end -}}

{{- define "deltav.selectorLabels" -}}
app.kubernetes.io/name: {{ include "deltav.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Resolved Kafka bootstrap servers. Single source of truth: every daemon and
hook injects this. Default matches the compose hostname so the bundled Kafka
subchart (fullnameOverride: kafka) and external endpoints both work.
*/}}
{{- define "deltav.kafkaBootstrap" -}}
{{- .Values.global.kafka.bootstrapServers | default "kafka:9092" -}}
{{- end -}}

{{/* Resolved PostgreSQL host / JDBC URL. */}}
{{- define "deltav.pgHost" -}}
{{- .Values.global.postgres.host | default "postgres" -}}
{{- end -}}

{{- define "deltav.jdbcUrl" -}}
{{- $pg := .Values.global.postgres -}}
{{- printf "jdbc:postgresql://%s:%v/%s" (include "deltav.pgHost" .) ($pg.port | default 5432) ($pg.database | default "opennms") -}}
{{- end -}}

{{/* Name of the Secret holding the DB password (existing or chart-managed). */}}
{{- define "deltav.dbSecretName" -}}
{{- if .Values.global.postgres.existingSecret -}}
{{- .Values.global.postgres.existingSecret -}}
{{- else -}}
{{- printf "%s-db" (include "deltav.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Fully-qualified container image reference. Call with a dict:
  (dict "root" $ "repo" "alarmd")
*/}}
{{- define "deltav.image" -}}
{{- $img := .root.Values.global.image -}}
{{- printf "%s/%s:%s" $img.registry .repo ($img.tag | default .root.Chart.AppVersion) -}}
{{- end -}}
