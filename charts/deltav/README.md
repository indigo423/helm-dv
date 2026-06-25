# deltav

![Version: 0.2.0](https://img.shields.io/badge/Version-0.2.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 1.3.0](https://img.shields.io/badge/AppVersion-1.3.0-informational?style=flat-square)

Delta-V — composable, containerized OpenNMS Horizon. Deploys the Spring Boot
daemon plane (alarmd, pollerd, collectd, …), the flow pipeline, and the Minion
ingress plane (envoy + minion-gateway). Backing services (PostgreSQL, Kafka,
ClickHouse, VictoriaMetrics, Grafana) are optional, condition-gated subcharts:
off by default (point at external/operator-managed instances); flipped on by
the bundled values-demo.yaml for a self-contained in-cluster demo.

This chart is derived from the Delta-V `deploy/compose.yml` reference topology.
Compose remains the local dev/E2E path; this chart is the Kubernetes deployment
surface.

## What it deploys

| Group | Components |
|---|---|
| Daemons (generic template over `.Values.daemons`) | alarmd, pollerd, collectd, discovery, provisiond, trapd, syslogd, eventtranslator, enlinkd, bsmd, perspectivepollerd, telemetryd, flow-enricher, alarms-materializer, prometheus-writer\*, alerts-forwarder\* |
| Minion ingress (always on) | envoy (gRPC h2c :8443) → minion-gateway → Kafka |
| Minion agent (optional) | one in-chart Minion for the demo; production Minions deploy separately |
| Schema init (Helm hooks) | db-init (`pre-install` for external/demo-legacy; `post-install` for CNPG modes), clickhouse-init |
| PostgreSQL backing | per `global.postgres.mode`: external · CloudNativePG `Cluster` (`managed`/`demo`) · raw Deployment (`demo-legacy`) — see [below](#postgresql-backing-modes) |
| Demo Kafka (first-party, optional) | Kafka via `templates/demo-backing.yaml` (`demoBackingServices.enabled`) |
| Optional subcharts (non-Bitnami) | victoria-metrics-single, grafana |

\* `prometheus-writer` and `alerts-forwarder` are off by default — they need a
remote-write target / Alertmanager URL.

> **No Bitnami.** Following the Aug–Sep 2025 Bitnami catalog deprecation, the
> demo PostgreSQL/Kafka are shipped as first-party single-node manifests (not
> subcharts). For **production**, run external/operator-managed datastores —
> e.g. [CloudNativePG](https://cloudnative-pg.io/) (Postgres),
> [Strimzi](https://strimzi.io/) (Kafka, KRaft), [Altinity](https://github.com/Altinity/clickhouse-operator)
> (ClickHouse), or [KubeBlocks](https://kubeblocks.io/) — and point `global.*` at them.
> ClickHouse is no longer bundled; supply an external one for the flow pipeline.

## PostgreSQL backing modes

PostgreSQL is selected per deployment via **`global.postgres.mode`**:

| Mode | What it renders | Use for |
|---|---|---|
| `external` *(default)* | Nothing — daemons wire to `global.postgres.host` + `existingSecret`. | Production with a managed/external Postgres (RDS, Cloud SQL, operator-managed elsewhere). |
| `managed` | A **CloudNativePG `Cluster`** — 3 instances, pod anti-affinity, dedicated WAL storage. | Production, self-contained HA Postgres in-cluster. |
| `demo` | A single-instance CloudNativePG `Cluster` (ephemeral). | Self-contained demo. |
| `demo-legacy` | The first-party single-node `postgres:16` Deployment (operator-free). | Lightweight demo / rollback. |

`external` renders byte-identical to prior releases, so it stays the safe default.

**Prerequisites for `managed`/`demo`:** the [CloudNativePG operator](https://cloudnative-pg.io/)
must already be installed (assume-installed — the chart does not vendor it), on
**Kubernetes ≥ 1.29**:

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace --version 0.28.3 --wait
```

In `managed` mode you **must** set a non-default `global.postgres.password` (or a
`global.postgres.existingSecret` — a `kubernetes.io/basic-auth` Secret whose
`username` equals `global.postgres.username`); the chart refuses the insecure
default. `global.postgres.passwordKey` must be `password` in `managed`/`demo`
(CloudNativePG fixes the secret key names).

> **Upgrade note (`managed`/`demo`):** schema migration (`db-init`) runs **once at
> install** (a `post-install` hook), and is **not** re-run on `helm upgrade` — the
> bundled `db-init` image (1.3.0) cannot re-run against an existing schema (an
> upstream `Migrator.databaseSetOwner` bug). For an app-version bump that needs new
> Liquibase changesets, run the migration manually until the upstream fix lands.

> **Not yet covered:** PostgreSQL 18 (the chart targets PG 16; PG 18 needs the
> OpenNMS installer `-Q` version-gate and PL/pgSQL IPLIKE) and CloudNativePG
> backups / PITR (Barman Cloud Plugin + cert-manager) are planned follow-ups.

## Other backing services (Kafka, ClickHouse, metrics, Grafana)

Every backing service is selected by a `mode` enum, mirroring `global.postgres.mode`.
**Kafka** is required (default `external`); **ClickHouse**, **metrics** and **Grafana**
are optional (default `off` — render/wire nothing). `managed` is reserved for the
operator implementations (Strimzi/Altinity/VictoriaMetrics/Grafana) and currently
fails fast with a directive. With no auth/TLS configured, `external` renders
byte-identical to prior releases.

| Service | Key | Bring-your-own (`external`) | Auth secret |
|---|---|---|---|
| Kafka | `global.kafka.mode` | `global.kafka.bootstrapServers` | SASL via `global.kafka.security` (see below) |
| ClickHouse | `global.clickhouse.mode` | `global.clickhouse.host` (+ `auth.username`) | `global.clickhouse.auth.existingSecret` (key `password`) |
| metrics | `global.metrics.mode` | `global.metrics.remoteWriteUrl` (any Prometheus remote-write target) | `global.metrics.auth` (`type: bearer\|basic` + `existingSecret`) |
| Grafana | `global.grafana.mode` | *(artifact emission — planned)* | — |

**Authenticated Kafka (SASL + TLS).** For a shared broker (MSK, Confluent Cloud,
Aiven, Strimzi-with-SCRAM): set the non-secret protocol/mechanism, and supply the
credential as a JAAS file in a Secret (it is mounted and referenced JVM-wide — it
never lands in the pod spec or `-D`). TLS uses **PEM** (a `kubernetes.io/tls` Secret,
cert-manager's shape) — no truststore password.

```bash
# SASL credential: the full sasl.jaas.config line under key jaas.conf
kubectl create secret generic kafka-creds \
  --from-literal=jaas.conf='org.apache.kafka.common.security.scram.ScramLoginModule required username="dv" password="…";'

helm install deltav oci://ghcr.io/indigo423/helm-dv/deltav \
  --set global.kafka.bootstrapServers=broker.example:9093 \
  --set global.kafka.security.protocol=SASL_SSL \
  --set global.kafka.security.saslMechanism=SCRAM-SHA-512 \
  --set global.kafka.security.existingSecret=kafka-creds \
  --set global.kafka.tls.existingSecret=kafka-tls    # kubernetes.io/tls (ca.crt[, tls.crt/tls.key + tls.mutual=true for mTLS])
```

**ClickHouse** (`external` = schema-only; the flow→ClickHouse writer is out-of-chart):
`--set global.clickhouse.mode=external --set global.clickhouse.host=ch.example
--set global.clickhouse.auth.existingSecret=ch-creds`. TLS: set
`global.clickhouse.tls.existingSecret` (a CA bundle under `ca.crt`) — the chart mounts
a secure `clickhouse-client` config (native port 9440).

**Metrics** remote-write auth: `--set global.metrics.mode=external
--set global.metrics.remoteWriteUrl=https://vm.example/api/v1/write
--set global.metrics.auth.type=bearer --set global.metrics.auth.existingSecret=vm-token`
(bearer → key `token`; basic → keys `username`/`password`). Enable the pusher with
`daemons.prometheus-writer.enabled=true`.

## Install

### Production (external/operator-managed backing services)

Demo datastores are **off** by default. Point the daemons at existing Kafka,
PostgreSQL and ClickHouse. Images default to the public `ghcr.io/pbrane/*` registry.

```bash
helm install deltav oci://ghcr.io/indigo423/helm-dv/deltav \
  --set global.kafka.bootstrapServers=my-kafka-bootstrap:9092 \
  --set global.postgres.host=my-postgres.db.svc \
  --set global.postgres.existingSecret=deltav-db
```

Provide the DB password via `global.postgres.existingSecret` (a Secret with a
`password` key). Without it the chart creates one from `global.postgres.password`
(non-production only).

### Self-contained demo (CloudNativePG Postgres + first-party Kafka)

Brings up the daemon plane plus a CloudNativePG-managed single-node PostgreSQL
(`mode: demo`) and a first-party Kafka on kind/minikube. **Requires the
CloudNativePG operator** (see Prerequisites above). The flow pipeline (ClickHouse)
is not bundled and is disabled in this preset.

```bash
# install the CloudNativePG operator first (see "PostgreSQL backing modes"), then:
helm repo add deltav https://indigo423.github.io/helm-dv
helm install deltav deltav/deltav -f https://raw.githubusercontent.com/indigo423/helm-dv/main/charts/deltav/values-demo.yaml
```

The demo Kafka is a `pre-install` hook (weight `-20`); the CloudNativePG `Cluster`
is a normal resource and `db-init` runs as a `post-install` hook once it is Ready.
For an **operator-free** demo, set `global.postgres.mode: demo-legacy` (the raw
single-node `postgres:16` Deployment).

## Key design points

- **Config is baked into the images** (`/opt/deltav/etc`), so daemons are
  configured through environment variables — no ConfigMaps. The only persisted,
  mutable config is provisiond's requisition seed (a PVC seeded by an initContainer).
- **Schema init runs as Helm hooks** (`pre-install`/`pre-upgrade`); ordering is
  handled by hooks + readiness probes, not `depends_on`. The DB Secret is itself
  a hook (weight -10) so it exists before the db-init hook (weight -5).
- **Adding a daemon is a values entry**, not a new template — every daemon renders
  from `templates/_daemon.tpl` ranged over `.Values.daemons`.
- **UDP ingress** (Minion trap/syslog/flow on 1162/1514/4729) needs a UDP-capable
  Service — `LoadBalancer` on cloud/MetalLB, `NodePort` on kind/minikube.

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| Delta-V |  |  |

## Source Code

* <https://github.com/pbrane/delta-v>

## Requirements

Kubernetes: `>=1.25.0-0`

| Repository | Name | Version |
|------------|------|---------|
| https://grafana.github.io/helm-charts | grafana | 10.5.15 |
| https://victoriametrics.github.io/helm-charts/ | victoriametrics(victoria-metrics-single) | 0.40.1 |

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| daemons | object | `{"alarmd":{"consumerGroup":"opennms-alarmd","enabled":true,"javaOpts":"-Xms512m -Xmx1g -XX:MaxMetaspaceSize=256m","tsidNodeId":23},"alarms-materializer":{"enabled":true,"extraEnv":{"DELTAV_ALARMS_STATE_TOPIC":"deltav-alarms-state-change","SPRING_KAFKA_BOOTSTRAP_SERVERS":"{{ include \"deltav.kafkaBootstrap\" . }}"},"usesKafka":false},"alerts-forwarder":{"enabled":false,"extraEnv":{"DELTAV_ALERTS_ALERTMANAGER_ENABLED":"false","DELTAV_ALERTS_ALERTMANAGER_URL":"","DELTAV_ALERTS_VM_ENABLED":"true","SPRING_KAFKA_BOOTSTRAP_SERVERS":"{{ include \"deltav.kafkaBootstrap\" . }}"},"probeInitialDelay":30,"usesDatabase":false,"usesKafka":false},"bsmd":{"consumerGroup":"opennms-bsmd","enabled":true,"javaOpts":"-Xms256m -Xmx512m -XX:MaxMetaspaceSize=256m -Dorg.opennms.alarms.snapshot.sync.ms=10000","tsidNodeId":17},"collectd":{"enabled":true,"extraEnv":{"DELTAV_TIMESERIES_ENABLED":"true","OPENNMS_TIMESERIES_STRATEGY":"inmemory"},"javaOpts":"-Xms512m -Xmx1g -Dorg.opennms.tsid.node-id=5","stopGracePeriodSeconds":60},"discovery":{"enabled":true,"extraEnv":{"INTERFACE_NODE_CACHE_REFRESH_MS":"15000","RPC_KAFKA_BOOTSTRAP_SERVERS":"{{ include \"deltav.kafkaBootstrap\" . }}","RPC_KAFKA_FORCE_REMOTE":"true"},"javaOpts":"-Xms256m -Xmx512m -XX:MaxMetaspaceSize=256m","stopGracePeriodSeconds":60,"tsidNodeId":24},"enlinkd":{"consumerGroup":"enlinkd","enabled":true,"extraEnv":{"OPENNMS_RPC_KAFKA_ENABLED":"true"},"javaOpts":"-Xms256m -Xmx512m -XX:MaxMetaspaceSize=256m -Dopennms.home=/opt/deltav","stopGracePeriodSeconds":60},"eventtranslator":{"consumerGroup":"opennms-eventtranslator","enabled":true,"javaOpts":"-Xms256m -Xmx512m -XX:MaxMetaspaceSize=256m","tsidNodeId":22},"flow-enricher":{"enabled":true,"extraEnv":{"DELTAV_FLOWS_DNS_ENABLED":"true","DELTAV_FLOWS_DNS_SCOPE":"all","DELTAV_FLOWS_OUTPUT_TOPIC":"deltav-flows","DELTAV_FLOWS_SINK_TOPICS":"DeltaV.Sink.Telemetry-Netflow-5,DeltaV.Sink.Telemetry-Netflow-9,DeltaV.Sink.Telemetry-IPFIX,DeltaV.Sink.Telemetry-SFlow"},"javaOpts":"-Xms256m -Xmx512m -XX:MaxMetaspaceSize=256m","probeInitialDelay":30},"perspectivepollerd":{"consumerGroup":"opennms-perspectivepollerd","enabled":true,"extraEnv":{"DELTAV_PERSPECTIVE_TIMESERIES_ENABLED":"true","OPENNMS_RPC_KAFKA_BOOTSTRAP_SERVERS":"{{ include \"deltav.kafkaBootstrap\" . }}","OPENNMS_RPC_KAFKA_ENABLED":"true"},"javaOpts":"-Xms512m -Xmx1g -XX:MaxMetaspaceSize=256m -Dorg.opennms.core.ipc.rpc.force-remote=true","tsidNodeId":7},"pollerd":{"consumerGroup":"opennms-pollerd","enabled":true,"extraEnv":{"DELTAV_TIMESERIES_ENABLED":"true","OPENNMS_RPC_KAFKA_BOOTSTRAP_SERVERS":"{{ include \"deltav.kafkaBootstrap\" . }}","OPENNMS_RPC_KAFKA_ENABLED":"true"},"javaOpts":"-Xms512m -Xmx1g -XX:MaxMetaspaceSize=256m -Dorg.opennms.core.ipc.twin.kafka.bootstrap.servers={{ include \"deltav.kafkaBootstrap\" . }} -Dorg.opennms.core.ipc.rpc.force-remote=true","tsidNodeId":4},"prometheus-writer":{"enabled":false,"extraEnv":{"JAVA_TOOL_OPTIONS":"-Xms128m -Xmx512m","PROMETHEUS_WRITER_REMOTE_WRITE_URL":"{{ include \"deltav.metricsRemoteWriteUrl\" . }}","SPRING_KAFKA_BOOTSTRAP_SERVERS":"{{ include \"deltav.kafkaBootstrap\" . }}"},"metricsRemoteWrite":true,"probePath":"/actuator/health/readiness","usesDatabase":false,"usesKafka":false},"provisiond":{"enabled":true,"extraEnv":{"RPC_KAFKA_BOOTSTRAP_SERVERS":"{{ include \"deltav.kafkaBootstrap\" . }}","RPC_KAFKA_ENABLED":"true","RPC_KAFKA_FORCE_REMOTE":"true"},"hostAliases":[{"hostnames":["mhuot-lab-2"],"ip":"172.20.20.2"},{"hostnames":["mhuot-lab-3"],"ip":"172.20.20.3"},{"hostnames":["mhuot-lab-4"],"ip":"172.20.20.4"},{"hostnames":["mhuot-lab-5"],"ip":"172.20.20.5"},{"hostnames":["mhuot-lab-6"],"ip":"172.20.20.6"}],"javaOpts":"-Xms512m -Xmx1g -XX:MaxMetaspaceSize=256m","probeInitialDelay":60,"seed":{"enabled":true,"image":"provisiond-imports-init","mountPath":"/opt/deltav/etc/imports","size":"1Gi"},"stopGracePeriodSeconds":60,"tsidNodeId":25},"syslogd":{"consumerGroup":"opennms-syslogd","enabled":true,"extraEnv":{"INTERFACE_NODE_CACHE_REFRESH_MS":"15000"},"javaOpts":"-Xms256m -Xmx512m -XX:MaxMetaspaceSize=256m","sinkConsumerGroup":"opennms-syslogd-sink","tsidNodeId":21},"telemetryd":{"consumerGroup":"opennms-telemetryd","enabled":true,"javaOpts":"-Xms256m -Xmx512m -XX:MaxMetaspaceSize=256m -Dorg.opennms.core.ipc.sink.kafka.bootstrap.servers={{ include \"deltav.kafkaBootstrap\" . }} -Dorg.opennms.core.ipc.sink.kafka.group.id=opennms-telemetryd-sink -Dorg.opennms.core.ipc.twin.kafka.bootstrap.servers={{ include \"deltav.kafkaBootstrap\" . }}","tsidNodeId":18},"trapd":{"consumerGroup":"opennms-trapd","enabled":true,"extraEnv":{"INTERFACE_NODE_CACHE_REFRESH_MS":"15000"},"javaOpts":"-Xms256m -Xmx512m -XX:MaxMetaspaceSize=256m","sinkConsumerGroup":"opennms-trapd-sink","tsidNodeId":20}}` | ------------------------------------------------------------------------- |
| demoBackingServices | object | `{"enabled":false,"kafka":{"heapOpts":"-Xms256m -Xmx512m","image":"apache/kafka:3.9.1","resources":{}},"postgres":{"image":"postgres:16","resources":{}},"waitImage":"busybox:1.37"}` | ------------------------------------------------------------------------- |
| envoy.enabled | bool | `true` |  |
| envoy.image | string | `"envoy"` |  |
| envoy.replicas | int | `1` |  |
| envoy.resources | object | `{}` |  |
| envoy.service.port | int | `8443` |  |
| envoy.service.type | string | `"ClusterIP"` |  |
| fullnameOverride | string | `""` |  |
| global.clickhouse.auth.existingSecret | string | `""` |  |
| global.clickhouse.auth.password | string | `""` |  |
| global.clickhouse.auth.username | string | `""` |  |
| global.clickhouse.host | string | `""` |  |
| global.clickhouse.mode | string | `""` |  |
| global.clickhouse.tls.existingSecret | string | `""` |  |
| global.grafana.datasourceUrl | string | `""` |  |
| global.grafana.mode | string | `"off"` |  |
| global.image.pullPolicy | string | `"IfNotPresent"` |  |
| global.image.registry | string | `"ghcr.io/pbrane"` |  |
| global.image.tag | string | `""` |  |
| global.imagePullSecrets | list | `[]` |  |
| global.instanceId | string | `"DeltaV"` |  |
| global.kafka.bootstrapServers | string | `"kafka:9092"` |  |
| global.kafka.mode | string | `"external"` |  |
| global.kafka.security.existingSecret | string | `""` |  |
| global.kafka.security.protocol | string | `""` |  |
| global.kafka.security.saslMechanism | string | `""` |  |
| global.kafka.tls.existingSecret | string | `""` |  |
| global.kafka.tls.mutual | bool | `false` |  |
| global.metrics.auth.existingSecret | string | `""` |  |
| global.metrics.auth.type | string | `""` |  |
| global.metrics.mode | string | `"off"` |  |
| global.metrics.remoteWriteUrl | string | `"http://victoriametrics:8428/api/v1/write"` |  |
| global.postgres.database | string | `"opennms"` |  |
| global.postgres.existingSecret | string | `""` |  |
| global.postgres.host | string | `"postgres"` |  |
| global.postgres.mode | string | `"external"` |  |
| global.postgres.password | string | `"opennms"` |  |
| global.postgres.passwordKey | string | `"password"` |  |
| global.postgres.port | int | `5432` |  |
| global.postgres.username | string | `"opennms"` |  |
| grafana.enabled | bool | `false` |  |
| initJobs | object | `{"clickhouseInit":{"enabled":true,"flowsAggTtlDays":"90","flowsRawTtlDays":"14","image":"clickhouse-init"},"dbInit":{"enabled":true,"image":"db-init","javaToolOptions":"-Xms256m -Xmx512m"}}` | ------------------------------------------------------------------------- |
| metrics.serviceMonitor.enabled | bool | `false` |  |
| metrics.serviceMonitor.interval | string | `"15s"` |  |
| metrics.serviceMonitor.labels | object | `{}` |  |
| minion.enabled | bool | `false` |  |
| minion.gateway.host | string | `""` |  |
| minion.gateway.port | int | `8443` |  |
| minion.id | string | `"minion-default-01"` |  |
| minion.image | string | `"minion-boot"` |  |
| minion.javaOpts | string | `"-Xms256m -Xmx512m -Djava.security.egd=file:/dev/./urandom"` |  |
| minion.location | string | `"Default"` |  |
| minion.resources | object | `{}` |  |
| minion.udp.ports[0].name | string | `"trap"` |  |
| minion.udp.ports[0].port | int | `1162` |  |
| minion.udp.ports[0].protocol | string | `"UDP"` |  |
| minion.udp.ports[1].name | string | `"syslog"` |  |
| minion.udp.ports[1].port | int | `1514` |  |
| minion.udp.ports[1].protocol | string | `"UDP"` |  |
| minion.udp.ports[2].name | string | `"flow"` |  |
| minion.udp.ports[2].port | int | `4729` |  |
| minion.udp.ports[2].protocol | string | `"UDP"` |  |
| minion.udp.service.type | string | `"ClusterIP"` |  |
| minionGateway | object | `{"enabled":true,"image":"minion-gateway","javaOpts":"-Xms256m -Xmx512m","replicas":1,"resources":{}}` | ------------------------------------------------------------------------- |
| nameOverride | string | `""` |  |
| postgresCluster | object | `{"demo":{"instances":1,"parameters":{"max_connections":"350"},"resources":{},"storage":{"size":"1Gi","storageClass":""}},"imageName":"ghcr.io/cloudnative-pg/postgresql:16","managed":{"instances":3,"parameters":{"max_connections":"350"},"resources":{},"storage":{"size":"10Gi","storageClass":""},"walStorage":{"size":"2Gi","storageClass":""}}}` | ------------------------------------------------------------------------- |
| victoriametrics | object | `{"enabled":false}` | ------------------------------------------------------------------------- |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs](https://github.com/norwoodj/helm-docs).
Edit `README.md.gotmpl`, not `README.md`.
