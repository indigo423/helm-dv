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
Generic backing-service mode validator. Call with a dict:
  (dict "root" $ "service" "clickhouse" "mode" $mode "allowed" (list "off" "external" "managed" "demo"))
Fails rendering on an unknown value, or on `managed` (reserved until the operator
change lands). Returns the validated mode unchanged. Optional services include
"off" in their allowed set; required services (postgres/kafka) do not.
*/}}
{{- define "deltav.backingMode" -}}
{{- $svc := .service -}}
{{- $mode := .mode -}}
{{- $allowed := .allowed -}}
{{- if not (has $mode $allowed) -}}
{{- fail (printf "global.%s.mode must be one of %v, got %q" $svc $allowed $mode) -}}
{{- end -}}
{{- if eq $mode "managed" -}}
{{- $operators := dict "kafka" "Strimzi" "clickhouse" "Altinity" "metrics" "the VictoriaMetrics Operator" "grafana" "the Grafana Operator" -}}
{{- $op := index $operators $svc | default "the dedicated operator" -}}
{{- fail (printf "global.%s.mode: managed is not yet implemented in this chart — use external (bring-your-own), or track the %s operator change. See chart docs." $svc $op) -}}
{{- end -}}
{{- $mode -}}
{{- end -}}

{{/* Effective Kafka mode (required: external|managed|demo, default external). */}}
{{- define "deltav.kafka.mode" -}}
{{- include "deltav.backingMode" (dict "root" . "service" "kafka" "mode" (.Values.global.kafka.mode | default "external") "allowed" (list "external" "managed" "demo")) -}}
{{- end -}}

{{/*
Effective ClickHouse mode (optional: off|external|managed|demo, default off).
Deprecation shim: when global.clickhouse.mode is unset, the prior top-level
clickhouse.enabled/external toggles map to external (on) or off.
*/}}
{{- define "deltav.clickhouse.mode" -}}
{{- $g := .Values.global.clickhouse | default dict -}}
{{- $legacy := .Values.clickhouse | default dict -}}
{{- $mode := $g.mode | default (ternary "external" "off" (or $legacy.enabled $legacy.external | default false)) -}}
{{- include "deltav.backingMode" (dict "root" . "service" "clickhouse" "mode" $mode "allowed" (list "off" "external" "managed" "demo")) -}}
{{- end -}}

{{/* Effective metrics (remote-write target) mode (optional: off|external|managed|demo, default off). */}}
{{- define "deltav.metrics.mode" -}}
{{- include "deltav.backingMode" (dict "root" . "service" "metrics" "mode" (.Values.global.metrics.mode | default "off") "allowed" (list "off" "external" "managed" "demo")) -}}
{{- end -}}

{{/* Effective Grafana mode (optional: off|external|managed|demo, default off). */}}
{{- define "deltav.grafana.mode" -}}
{{- include "deltav.backingMode" (dict "root" . "service" "grafana" "mode" (.Values.global.grafana.mode | default "off") "allowed" (list "off" "external" "managed" "demo")) -}}
{{- end -}}

{{/*
Kafka external auth (resolved by the Phase-0 spike): the OpenNMS IPC namespaces
(sink/rpc/twin) read Kafka config only from JVM system properties, so non-secret
security goes via -D and the SASL credential via a mounted JAAS file referenced
JVM-wide (never -D/env, no leakage). TLS uses PEM — no truststore password. Mount
paths are fixed: TLS at /etc/deltav/kafka/tls, JAAS at /etc/deltav/kafka/jaas.
*/}}

{{/* "true" when any Kafka security/TLS is configured; empty otherwise. */}}
{{- define "deltav.kafkaSecurityActive" -}}
{{- $sec := .Values.global.kafka.security | default dict -}}
{{- $tls := .Values.global.kafka.tls | default dict -}}
{{- if or $sec.protocol $tls.existingSecret -}}true{{- end -}}
{{- end -}}

{{/* -D flags for the IPC namespaces (non-secret) + the JVM-wide JAAS login file. */}}
{{- define "deltav.kafkaSecurityJavaOpts" -}}
{{- $sec := .Values.global.kafka.security | default dict -}}
{{- $tls := .Values.global.kafka.tls | default dict -}}
{{- $opts := list -}}
{{- range $ns := (list "sink" "rpc" "twin") -}}
{{- if $sec.protocol -}}
{{- $opts = append $opts (printf "-Dorg.opennms.core.ipc.%s.kafka.security.protocol=%s" $ns $sec.protocol) -}}
{{- if $sec.saslMechanism -}}{{- $opts = append $opts (printf "-Dorg.opennms.core.ipc.%s.kafka.sasl.mechanism=%s" $ns $sec.saslMechanism) -}}{{- end -}}
{{- end -}}
{{- if $tls.existingSecret -}}
{{- $opts = append $opts (printf "-Dorg.opennms.core.ipc.%s.kafka.ssl.truststore.type=PEM" $ns) -}}
{{- $opts = append $opts (printf "-Dorg.opennms.core.ipc.%s.kafka.ssl.truststore.location=/etc/deltav/kafka/tls/ca.crt" $ns) -}}
{{- if $tls.mutual -}}
{{- $opts = append $opts (printf "-Dorg.opennms.core.ipc.%s.kafka.ssl.keystore.type=PEM" $ns) -}}
{{- $opts = append $opts (printf "-Dorg.opennms.core.ipc.%s.kafka.ssl.keystore.location=/etc/deltav/kafka/tls/tls.crt" $ns) -}}
{{- $opts = append $opts (printf "-Dorg.opennms.core.ipc.%s.kafka.ssl.keystore.key=/etc/deltav/kafka/tls/tls.key" $ns) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $sec.existingSecret -}}{{- $opts = append $opts "-Djava.security.auth.login.config=/etc/deltav/kafka/jaas/jaas.conf" -}}{{- end -}}
{{- join " " $opts -}}
{{- end -}}

{{/* Spring/Spring-Cloud-Stream security env (KafkaAdmin + binder clients). */}}
{{- define "deltav.kafkaSecurityEnv" -}}
{{- $sec := .Values.global.kafka.security | default dict -}}
{{- $tls := .Values.global.kafka.tls | default dict -}}
{{- if $sec.protocol -}}
- name: SPRING_KAFKA_PROPERTIES_SECURITY_PROTOCOL
  value: {{ $sec.protocol | quote }}
- name: SPRING_CLOUD_STREAM_KAFKA_BINDER_CONFIGURATION_SECURITY_PROTOCOL
  value: {{ $sec.protocol | quote }}
{{- if $sec.saslMechanism }}
- name: SPRING_KAFKA_PROPERTIES_SASL_MECHANISM
  value: {{ $sec.saslMechanism | quote }}
- name: SPRING_CLOUD_STREAM_KAFKA_BINDER_CONFIGURATION_SASL_MECHANISM
  value: {{ $sec.saslMechanism | quote }}
{{- end }}
{{- end }}
{{- if $tls.existingSecret }}
- name: SPRING_KAFKA_PROPERTIES_SSL_TRUSTSTORE_TYPE
  value: PEM
- name: SPRING_KAFKA_PROPERTIES_SSL_TRUSTSTORE_LOCATION
  value: /etc/deltav/kafka/tls/ca.crt
- name: SPRING_CLOUD_STREAM_KAFKA_BINDER_CONFIGURATION_SSL_TRUSTSTORE_TYPE
  value: PEM
- name: SPRING_CLOUD_STREAM_KAFKA_BINDER_CONFIGURATION_SSL_TRUSTSTORE_LOCATION
  value: /etc/deltav/kafka/tls/ca.crt
{{- if $tls.mutual }}
- name: SPRING_KAFKA_PROPERTIES_SSL_KEYSTORE_TYPE
  value: PEM
- name: SPRING_KAFKA_PROPERTIES_SSL_KEYSTORE_LOCATION
  value: /etc/deltav/kafka/tls/tls.crt
- name: SPRING_KAFKA_PROPERTIES_SSL_KEYSTORE_KEY
  value: /etc/deltav/kafka/tls/tls.key
{{- end }}
{{- end }}
{{- end -}}

{{/* "true" when metrics remote-write auth is configured (type + secret). */}}
{{- define "deltav.metricsAuthActive" -}}
{{- $a := .Values.global.metrics.auth | default dict -}}
{{- if and ($a.type | default "") ($a.existingSecret | default "") -}}true{{- end -}}
{{- end -}}

{{/*
Metrics remote-write auth env for prometheus-writer, from global.metrics.auth.
Bearer → token key; basic → username/password keys. Secret-backed, no plaintext.
*/}}
{{- define "deltav.metricsAuthEnv" -}}
{{- $a := .Values.global.metrics.auth | default dict -}}
{{- $type := $a.type | default "" -}}
{{- $secret := $a.existingSecret | default "" -}}
- name: PROMETHEUS_WRITER_AUTH_TYPE
  value: {{ $type | quote }}
{{- if eq $type "bearer" }}
- name: PROMETHEUS_WRITER_BEARER_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: token
{{- else if eq $type "basic" }}
- name: PROMETHEUS_WRITER_BASIC_USER
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: username
- name: PROMETHEUS_WRITER_BASIC_PASS
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: password
{{- end }}
{{- end -}}

{{/*
Validate every backing-service mode on each render. Emits nothing; fails fast on
an unknown or not-yet-implemented (managed) value for any service. Invoked once
from an always-rendered template (daemons.yaml).
*/}}
{{- define "deltav.validateModes" -}}
{{- $m := include "deltav.kafka.mode" . -}}
{{- $m = include "deltav.clickhouse.mode" . -}}
{{- $m = include "deltav.metrics.mode" . -}}
{{- $m = include "deltav.grafana.mode" . -}}
{{/* A mounted Kafka SASL credential is inert without a security protocol — fail loudly. */}}
{{- $ksec := .Values.global.kafka.security | default dict -}}
{{- if and ($ksec.existingSecret | default "") (not ($ksec.protocol | default "")) -}}
{{- fail "global.kafka.security.existingSecret is set but global.kafka.security.protocol is empty — set the protocol (e.g. SASL_SSL) so the mounted JAAS credential is actually used." -}}
{{- end -}}
{{/* Metrics remote-write auth type must be a known scheme. */}}
{{- $mauth := .Values.global.metrics.auth | default dict -}}
{{- if and ($mauth.type | default "") (not (has ($mauth.type) (list "bearer" "basic"))) -}}
{{- fail (printf "global.metrics.auth.type must be one of [bearer basic], got %q" $mauth.type) -}}
{{- end -}}
{{- end -}}

{{/*
Kafka security volume mounts + volumes (kafka-tls, kafka-jaas), gated on the
respective existingSecret. Shared by _daemon.tpl-style components and the
minion-gateway. Call with the root context.
*/}}
{{- define "deltav.kafkaSecurityVolumeMounts" -}}
{{- $tls := .Values.global.kafka.tls | default dict -}}
{{- $sec := .Values.global.kafka.security | default dict -}}
{{- $mounts := list -}}
{{- if $tls.existingSecret -}}{{- $mounts = append $mounts (dict "name" "kafka-tls" "mountPath" "/etc/deltav/kafka/tls" "readOnly" true) -}}{{- end -}}
{{- if $sec.existingSecret -}}{{- $mounts = append $mounts (dict "name" "kafka-jaas" "mountPath" "/etc/deltav/kafka/jaas" "readOnly" true) -}}{{- end -}}
{{- toYaml $mounts -}}
{{- end -}}

{{- define "deltav.kafkaSecurityVolumes" -}}
{{- $tls := .Values.global.kafka.tls | default dict -}}
{{- $sec := .Values.global.kafka.security | default dict -}}
{{- $vols := list -}}
{{- if $tls.existingSecret -}}{{- $vols = append $vols (dict "name" "kafka-tls" "secret" (dict "secretName" $tls.existingSecret)) -}}{{- end -}}
{{- if $sec.existingSecret -}}{{- $vols = append $vols (dict "name" "kafka-jaas" "secret" (dict "secretName" $sec.existingSecret)) -}}{{- end -}}
{{- toYaml $vols -}}
{{- end -}}

{{/*
Resolved ClickHouse host. Coalesces global.clickhouse.host (new) → top-level
clickhouse.host (deprecated shim) → "clickhouse". Single source for the
clickhouse-init Job's connection.
*/}}
{{- define "deltav.clickhouseHost" -}}
{{- $g := .Values.global.clickhouse | default dict -}}
{{- $legacy := .Values.clickhouse | default dict -}}
{{- coalesce $g.host $legacy.host "clickhouse" -}}
{{- end -}}

{{/*
Resolved metrics remote-write URL. Single source of truth for the
prometheus-writer / alerts-forwarder push target. Default matches the demo VM
service so the bundled subchart and external endpoints both work.
*/}}
{{- define "deltav.metricsRemoteWriteUrl" -}}
{{- $m := .Values.global.metrics | default dict -}}
{{- $m.remoteWriteUrl | default "http://victoriametrics:8428/api/v1/write" -}}
{{- end -}}

{{/*
Resolved Grafana datasource URL — the read endpoint of the metrics backend.
Derives from the metrics remote-write URL (strips the /api/v1/write suffix) so
Grafana and prometheus-writer agree on one metrics store.
*/}}
{{- define "deltav.grafanaDatasourceUrl" -}}
{{- $g := .Values.global.grafana | default dict -}}
{{- if $g.datasourceUrl -}}
{{- $g.datasourceUrl -}}
{{- else -}}
{{- include "deltav.metricsRemoteWriteUrl" . | trimSuffix "/api/v1/write" -}}
{{- end -}}
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
