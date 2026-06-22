# deltav

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 1.3.0](https://img.shields.io/badge/AppVersion-1.3.0-informational?style=flat-square)

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
| Schema init (Helm hooks) | db-init, clickhouse-init (`pre-install`/`pre-upgrade`) |
| Demo datastores (first-party, optional) | PostgreSQL + Kafka via `templates/demo-backing.yaml` (`demoBackingServices.enabled`) |
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

### Self-contained demo (first-party backing services)

Brings up the daemon plane plus first-party PostgreSQL + Kafka on kind/minikube
(no Bitnami, no external datastores). The flow pipeline (ClickHouse) is not
bundled and is disabled in this preset.

```bash
helm repo add deltav https://indigo423.github.io/helm-dv
helm install deltav deltav/deltav -f https://raw.githubusercontent.com/indigo423/helm-dv/main/charts/deltav/values-demo.yaml
```

The demo `postgres`/`kafka` are delivered as `pre-install` hooks (weight `-20`)
so they come up before the `db-init` schema hook (`-5`).

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
| clickhouse.auth.password | string | `"deltav"` |  |
| clickhouse.auth.username | string | `"deltav"` |  |
| clickhouse.enabled | bool | `false` |  |
| clickhouse.external | bool | `false` |  |
| clickhouse.host | string | `"clickhouse"` |  |
| daemons | object | `{"alarmd":{"consumerGroup":"opennms-alarmd","enabled":true,"javaOpts":"-Xms512m -Xmx1g -XX:MaxMetaspaceSize=256m","tsidNodeId":23},"alarms-materializer":{"enabled":true,"extraEnv":{"DELTAV_ALARMS_STATE_TOPIC":"deltav-alarms-state-change","SPRING_KAFKA_BOOTSTRAP_SERVERS":"{{ include \"deltav.kafkaBootstrap\" . }}"},"usesKafka":false},"alerts-forwarder":{"enabled":false,"extraEnv":{"DELTAV_ALERTS_ALERTMANAGER_ENABLED":"false","DELTAV_ALERTS_ALERTMANAGER_URL":"","DELTAV_ALERTS_VM_ENABLED":"true","SPRING_KAFKA_BOOTSTRAP_SERVERS":"{{ include \"deltav.kafkaBootstrap\" . }}"},"probeInitialDelay":30,"usesDatabase":false,"usesKafka":false},"bsmd":{"consumerGroup":"opennms-bsmd","enabled":true,"javaOpts":"-Xms256m -Xmx512m -XX:MaxMetaspaceSize=256m -Dorg.opennms.alarms.snapshot.sync.ms=10000","tsidNodeId":17},"collectd":{"enabled":true,"extraEnv":{"DELTAV_TIMESERIES_ENABLED":"true","OPENNMS_TIMESERIES_STRATEGY":"inmemory"},"javaOpts":"-Xms512m -Xmx1g -Dorg.opennms.tsid.node-id=5","stopGracePeriodSeconds":60},"discovery":{"enabled":true,"extraEnv":{"INTERFACE_NODE_CACHE_REFRESH_MS":"15000","RPC_KAFKA_BOOTSTRAP_SERVERS":"{{ include \"deltav.kafkaBootstrap\" . }}","RPC_KAFKA_FORCE_REMOTE":"true"},"javaOpts":"-Xms256m -Xmx512m -XX:MaxMetaspaceSize=256m","stopGracePeriodSeconds":60,"tsidNodeId":24},"enlinkd":{"consumerGroup":"enlinkd","enabled":true,"extraEnv":{"OPENNMS_RPC_KAFKA_ENABLED":"true"},"javaOpts":"-Xms256m -Xmx512m -XX:MaxMetaspaceSize=256m -Dopennms.home=/opt/deltav","stopGracePeriodSeconds":60},"eventtranslator":{"consumerGroup":"opennms-eventtranslator","enabled":true,"javaOpts":"-Xms256m -Xmx512m -XX:MaxMetaspaceSize=256m","tsidNodeId":22},"flow-enricher":{"enabled":true,"extraEnv":{"DELTAV_FLOWS_DNS_ENABLED":"true","DELTAV_FLOWS_DNS_SCOPE":"all","DELTAV_FLOWS_OUTPUT_TOPIC":"deltav-flows","DELTAV_FLOWS_SINK_TOPICS":"DeltaV.Sink.Telemetry-Netflow-5,DeltaV.Sink.Telemetry-Netflow-9,DeltaV.Sink.Telemetry-IPFIX,DeltaV.Sink.Telemetry-SFlow"},"javaOpts":"-Xms256m -Xmx512m -XX:MaxMetaspaceSize=256m","probeInitialDelay":30},"perspectivepollerd":{"consumerGroup":"opennms-perspectivepollerd","enabled":true,"extraEnv":{"DELTAV_PERSPECTIVE_TIMESERIES_ENABLED":"true","OPENNMS_RPC_KAFKA_BOOTSTRAP_SERVERS":"{{ include \"deltav.kafkaBootstrap\" . }}","OPENNMS_RPC_KAFKA_ENABLED":"true"},"javaOpts":"-Xms512m -Xmx1g -XX:MaxMetaspaceSize=256m -Dorg.opennms.core.ipc.rpc.force-remote=true","tsidNodeId":7},"pollerd":{"consumerGroup":"opennms-pollerd","enabled":true,"extraEnv":{"DELTAV_TIMESERIES_ENABLED":"true","OPENNMS_RPC_KAFKA_BOOTSTRAP_SERVERS":"{{ include \"deltav.kafkaBootstrap\" . }}","OPENNMS_RPC_KAFKA_ENABLED":"true"},"javaOpts":"-Xms512m -Xmx1g -XX:MaxMetaspaceSize=256m -Dorg.opennms.core.ipc.twin.kafka.bootstrap.servers={{ include \"deltav.kafkaBootstrap\" . }} -Dorg.opennms.core.ipc.rpc.force-remote=true","tsidNodeId":4},"prometheus-writer":{"enabled":false,"extraEnv":{"JAVA_TOOL_OPTIONS":"-Xms128m -Xmx512m","PROMETHEUS_WRITER_REMOTE_WRITE_URL":"http://victoriametrics:8428/api/v1/write","SPRING_KAFKA_BOOTSTRAP_SERVERS":"{{ include \"deltav.kafkaBootstrap\" . }}"},"probePath":"/actuator/health/readiness","usesDatabase":false,"usesKafka":false},"provisiond":{"enabled":true,"extraEnv":{"RPC_KAFKA_BOOTSTRAP_SERVERS":"{{ include \"deltav.kafkaBootstrap\" . }}","RPC_KAFKA_ENABLED":"true","RPC_KAFKA_FORCE_REMOTE":"true"},"hostAliases":[{"hostnames":["mhuot-lab-2"],"ip":"172.20.20.2"},{"hostnames":["mhuot-lab-3"],"ip":"172.20.20.3"},{"hostnames":["mhuot-lab-4"],"ip":"172.20.20.4"},{"hostnames":["mhuot-lab-5"],"ip":"172.20.20.5"},{"hostnames":["mhuot-lab-6"],"ip":"172.20.20.6"}],"javaOpts":"-Xms512m -Xmx1g -XX:MaxMetaspaceSize=256m","probeInitialDelay":60,"seed":{"enabled":true,"image":"provisiond-imports-init","mountPath":"/opt/deltav/etc/imports","size":"1Gi"},"stopGracePeriodSeconds":60,"tsidNodeId":25},"syslogd":{"consumerGroup":"opennms-syslogd","enabled":true,"extraEnv":{"INTERFACE_NODE_CACHE_REFRESH_MS":"15000"},"javaOpts":"-Xms256m -Xmx512m -XX:MaxMetaspaceSize=256m","sinkConsumerGroup":"opennms-syslogd-sink","tsidNodeId":21},"telemetryd":{"consumerGroup":"opennms-telemetryd","enabled":true,"javaOpts":"-Xms256m -Xmx512m -XX:MaxMetaspaceSize=256m -Dorg.opennms.core.ipc.sink.kafka.bootstrap.servers={{ include \"deltav.kafkaBootstrap\" . }} -Dorg.opennms.core.ipc.sink.kafka.group.id=opennms-telemetryd-sink -Dorg.opennms.core.ipc.twin.kafka.bootstrap.servers={{ include \"deltav.kafkaBootstrap\" . }}","tsidNodeId":18},"trapd":{"consumerGroup":"opennms-trapd","enabled":true,"extraEnv":{"INTERFACE_NODE_CACHE_REFRESH_MS":"15000"},"javaOpts":"-Xms256m -Xmx512m -XX:MaxMetaspaceSize=256m","sinkConsumerGroup":"opennms-trapd-sink","tsidNodeId":20}}` | ------------------------------------------------------------------------- |
| demoBackingServices | object | `{"enabled":false,"kafka":{"heapOpts":"-Xms256m -Xmx512m","image":"apache/kafka:3.9.1","resources":{}},"postgres":{"image":"postgres:16","resources":{}},"waitImage":"busybox:1.37"}` | ------------------------------------------------------------------------- |
| envoy.enabled | bool | `true` |  |
| envoy.image | string | `"envoy"` |  |
| envoy.replicas | int | `1` |  |
| envoy.resources | object | `{}` |  |
| envoy.service.port | int | `8443` |  |
| envoy.service.type | string | `"ClusterIP"` |  |
| fullnameOverride | string | `""` |  |
| global.image.pullPolicy | string | `"IfNotPresent"` |  |
| global.image.registry | string | `"ghcr.io/pbrane"` |  |
| global.image.tag | string | `""` |  |
| global.imagePullSecrets | list | `[]` |  |
| global.instanceId | string | `"DeltaV"` |  |
| global.kafka.bootstrapServers | string | `"kafka:9092"` |  |
| global.postgres.database | string | `"opennms"` |  |
| global.postgres.existingSecret | string | `""` |  |
| global.postgres.host | string | `"postgres"` |  |
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
| victoriametrics | object | `{"enabled":false}` | ------------------------------------------------------------------------- |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs](https://github.com/norwoodj/helm-docs).
Edit `README.md.gotmpl`, not `README.md`.
