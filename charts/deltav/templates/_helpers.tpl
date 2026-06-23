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

{{/*
Effective backing-service mode for PostgreSQL. One of:
  external     - chart provisions nothing; wire to global.postgres.host + secret (default)
  managed      - CloudNativePG-provisioned HA Cluster (CNPG operator assumed installed)
  demo         - CloudNativePG-provisioned single-instance Cluster (ephemeral)
  demo-legacy  - first-party single-node postgres Deployment (rollback path)
Fails rendering on an unknown value.
*/}}
{{- define "deltav.postgres.mode" -}}
{{- $pg := .Values.global.postgres -}}
{{- $mode := $pg.mode | default "external" -}}
{{- if not (has $mode (list "external" "managed" "demo" "demo-legacy")) -}}
{{- fail (printf "global.postgres.mode must be one of [external managed demo demo-legacy], got %q" $mode) -}}
{{- end -}}
{{- if and (or (eq $mode "managed") (eq $mode "demo")) (ne ($pg.passwordKey | default "password") "password") -}}
{{- fail "global.postgres.passwordKey must be \"password\" when global.postgres.mode is managed or demo (CloudNativePG fixes the basic-auth secret keys to username/password)." -}}
{{- end -}}
{{- if and (eq $mode "managed") (not $pg.existingSecret) (or (not $pg.password) (eq $pg.password "opennms")) -}}
{{- fail "global.postgres.password must be set to a non-default, non-empty value when global.postgres.mode is managed (production); provide global.postgres.password or global.postgres.existingSecret — an empty or default \"opennms\" password is insecure." -}}
{{- end -}}
{{- $mode -}}
{{- end -}}

{{/*
Resolved PostgreSQL host. external/demo-legacy resolve to the configured host (single
source for the daemons' JDBC URL); managed/demo resolve to the CNPG read-write Service,
which always points at the current primary across failover.
*/}}
{{- define "deltav.pgHost" -}}
{{- $mode := include "deltav.postgres.mode" . -}}
{{- if or (eq $mode "managed") (eq $mode "demo") -}}
{{- printf "%s-pg-rw" (include "deltav.fullname" .) -}}
{{- else -}}
{{- .Values.global.postgres.host | default "postgres" -}}
{{- end -}}
{{- end -}}

{{- define "deltav.jdbcUrl" -}}
{{- $pg := .Values.global.postgres -}}
{{- printf "jdbc:postgresql://%s:%v/%s" (include "deltav.pgHost" .) ($pg.port | default 5432) ($pg.database | default "opennms") -}}
{{- end -}}

{{/*
Name of the Secret holding the DB credentials (existing or chart-managed). Mode-agnostic:
the same secret the daemons consume is also fed to CNPG as the bootstrap secret in
managed/demo modes, so daemons and the Cluster always share one credential source.
*/}}
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
