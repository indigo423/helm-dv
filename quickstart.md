# Delta-V Quickstart

Step-by-step install guides for each PostgreSQL backing mode of the `deltav` chart,
selected by **`global.postgres.mode`**:

| Mode | PostgreSQL backing | Operator needed? | Guide |
|---|---|---|---|
| `external` *(default)* | your own / managed Postgres | no | [↓ External](#1-external-production-bring-your-own-postgres) |
| `managed` | CloudNativePG HA `Cluster` (3 instances) | **CloudNativePG** | [↓ Managed](#2-managed-production-cloudnativepg-ha) |
| `demo` | CloudNativePG single-node `Cluster` | **CloudNativePG** | [↓ Demo](#3-demo-self-contained-cloudnativepg) |
| `demo-legacy` | raw single-node `postgres:16` Deployment | no | [↓ Demo-legacy](#4-demo-legacy-operator-free-demo) |

> Full reference: [`charts/deltav/README.md`](charts/deltav/README.md).

## Prerequisites (all modes)

- `kubectl` pointed at a cluster, and `helm` ≥ 3.7.
- Add the chart repo (or use the OCI artifact directly):

  ```bash
  helm repo add deltav https://indigo423.github.io/helm-dv
  helm repo update deltav
  # OCI alternative: oci://ghcr.io/indigo423/helm-dv/deltav
  ```

- The examples use release name **`deltav`** (so the CNPG cluster is `deltav-pg`,
  the daemons are `deltav-alarmd`, etc.). The preset value files referenced below
  (`values-demo.yaml`, `values-managed.yaml`) live under `charts/deltav/`; pass a
  local path if you cloned the repo, or the raw GitHub URL otherwise.

---

## 1. External (production, bring-your-own backing services)

The chart provisions **no** datastores — your daemons connect to your existing
services. This is the default mode; each service is pointed at independently:

| Service | Point at your own with | Default |
|---|---|---|
| **PostgreSQL** | `global.postgres.host`, `.database`, `.username`, `.existingSecret` | `mode: external` |
| **Kafka** | `global.kafka.bootstrapServers` | `kafka:9092` |
| **ClickHouse** (flow schema) | `clickhouse.external=true`, `clickhouse.host`, `clickhouse.auth.username/password` — runs the `clickhouse-init` DDL (the flow→ClickHouse consumer is out-of-chart, see note) | `clickhouse-init` off |
| **VictoriaMetrics** (metrics) | keep `victoriametrics.enabled=false`; enable `daemons.prometheus-writer` and set its `PROMETHEUS_WRITER_REMOTE_WRITE_URL` to your VM remote-write endpoint | subchart off |
| **Grafana** (dashboards) | keep `grafana.enabled=false`; run your own Grafana and add your metrics store as a datasource | subchart off |

**1. Create a Secret with the DB password** (key `password`):

```bash
kubectl create secret generic deltav-db \
  --from-literal=password='<your-postgres-password>'
```

**2. Install, pointing at your services.** PostgreSQL + Kafka are the minimum; add
the ClickHouse / VictoriaMetrics lines only if you run those services (omit them
otherwise — this is one command):

```bash
helm install deltav deltav/deltav \
  --set global.postgres.host=my-postgres.db.svc \
  --set global.postgres.database=opennms \
  --set global.postgres.username=opennms \
  --set global.postgres.existingSecret=deltav-db \
  --set global.kafka.bootstrapServers=my-kafka-bootstrap:9092 \
  --set clickhouse.external=true \
  --set clickhouse.host=my-clickhouse.svc \
  --set clickhouse.auth.username=deltav \
  --set-string clickhouse.auth.password='<clickhouse-password>' \
  --set daemons.prometheus-writer.enabled=true \
  --set-string daemons.prometheus-writer.extraEnv.PROMETHEUS_WRITER_REMOTE_WRITE_URL=http://my-victoriametrics:8428/api/v1/write
```

> `global.postgres.mode` defaults to `external`. The **Grafana** and
> **VictoriaMetrics** subcharts stay off (`grafana.enabled=false`,
> `victoriametrics.enabled=false`) — bring your own and point Grafana's datasource
> at your metrics store. The `db-init` schema migration runs as a `pre-install`
> hook against your Postgres.
>
> **ClickHouse is schema-only here:** `clickhouse.external=true` runs the
> `clickhouse-init` DDL against your ClickHouse, and the `flow-enricher` daemon
> (on by default) publishes enriched flows to the Kafka topic `deltav-flows`. The
> consumer that *writes* those flows into ClickHouse is **not** part of this chart
> — supply your own.
>
> Use `--set-string` for URLs/passwords, and prefer a `-f my-values.yaml` overlay
> over a long `--set` chain (passwords containing `,` break bare `--set`).

**3. Verify:**

```bash
kubectl rollout status deploy/deltav-alarmd --timeout=300s
kubectl exec deploy/deltav-alarmd -- \
  curl -sf http://localhost:8080/actuator/health | grep '"status":"UP"'
```

**Uninstall:** `helm uninstall deltav` (your external Postgres is untouched).

---

## 2. Managed (production, CloudNativePG HA)

The chart provisions a **production-grade HA PostgreSQL** `Cluster` (3 instances,
pod anti-affinity, dedicated WAL storage) via the CloudNativePG operator.

**1. Prerequisites:** Kubernetes **≥ 1.29**, and the CloudNativePG operator installed:

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace --version 0.28.3 --wait
```

**2. Install with the managed preset and a strong password.** The chart *refuses*
to render a managed cluster with the default/empty password:

```bash
helm install deltav deltav/deltav \
  -f charts/deltav/values-managed.yaml \
  --set global.postgres.password='<strong-password>' \
  --set global.kafka.bootstrapServers=my-kafka-bootstrap:9092
```

> Prefer a pre-created Secret? Set `global.postgres.existingSecret` instead — it
> **must** be type `kubernetes.io/basic-auth` with keys `username` (= `opennms`)
> and `password`. Keep `global.postgres.passwordKey: password` (CNPG fixes the keys).
>
> Tune sizing in `values-managed.yaml` (`postgresCluster.managed.instances`,
> `storage.size`, `walStorage.size`).

**3. Verify the cluster, then the daemons:**

```bash
kubectl wait --for=condition=Ready --timeout=300s cluster/deltav-pg
kubectl get cluster deltav-pg      # READY 3/3, "Cluster in healthy state"
kubectl rollout status deploy/deltav-alarmd --timeout=600s
kubectl exec deploy/deltav-alarmd -- \
  curl -sf http://localhost:8080/actuator/health | grep '"status":"UP"'
```

> **Upgrade note:** schema migration runs **once at install** (a `post-install`
> hook); it is *not* re-run on `helm upgrade` (the bundled `db-init` image cannot
> re-run against an existing schema — upstream bug). For an app-version bump that
> needs new migrations, run them manually until the upstream fix lands.

**Uninstall:** `helm uninstall deltav`. ⚠️ The CNPG `Cluster` and its PVCs are
operator-owned and **persist** — delete them explicitly if you want the data gone:
`kubectl delete cluster deltav-pg`. Do **not** uninstall the CNPG operator/CRDs on
a shared cluster — that cascade-deletes every Cluster's data.

---

## 3. Demo (self-contained, CloudNativePG)

A single-node CloudNativePG Postgres + first-party Kafka — the operator-managed
demo on kind/minikube.

**1. Prerequisites:** a local cluster (e.g. `kind create cluster`) on K8s ≥ 1.29,
and the CloudNativePG operator (same as Managed step 1):

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace --version 0.28.3 --wait
```

**2. Install the demo preset** (sets `mode: demo`, a demo password, NodePort ingress):

```bash
helm install deltav deltav/deltav \
  -f https://raw.githubusercontent.com/indigo423/helm-dv/main/charts/deltav/values-demo.yaml
```

**3. Verify:**

```bash
kubectl wait --for=condition=Ready --timeout=300s cluster/deltav-pg
kubectl get pods   # CNPG deltav-pg-1, kafka, and the daemons converge
kubectl exec deploy/deltav-alarmd -- \
  curl -sf http://localhost:8080/actuator/health | grep '"status":"UP"'
```

> Or use the Makefile end-to-end smoke (installs the operator for you):
> `make kind-test`.

**Uninstall:** `helm uninstall deltav` (demo data is ephemeral).

---

## 4. Demo-legacy (operator-free demo)

The lightest demo: the prior raw single-node `postgres:16` Deployment — **no
operator required**. Use this on a cluster where you can't install CloudNativePG,
or as a rollback.

**1. No operator needed** — just a local cluster.

**2. Install the demo preset, overriding the mode:**

```bash
helm install deltav deltav/deltav \
  -f https://raw.githubusercontent.com/indigo423/helm-dv/main/charts/deltav/values-demo.yaml \
  --set global.postgres.mode=demo-legacy
```

**3. Verify:**

```bash
kubectl rollout status deploy/postgres --timeout=300s   # raw demo postgres
kubectl rollout status deploy/deltav-alarmd --timeout=600s
kubectl exec deploy/deltav-alarmd -- \
  curl -sf http://localhost:8080/actuator/health | grep '"status":"UP"'
```

> Here `db-init` is a `pre-install` hook and the demo `postgres`/`kafka` come up as
> `pre-install` hooks (weight `-20`) ahead of it. On `helm upgrade` the demo data
> is wiped (acceptable for an ephemeral demo).

**Uninstall:** `helm uninstall deltav`.

---

## Minion ingress (UDP traps/syslog/flows)

For Minion UDP ingress (trap/syslog/flow on 1162/1514/4729) you need a UDP-capable
Service: `LoadBalancer` on cloud/MetalLB, `NodePort` on kind/minikube (the demo
presets already set NodePort). See the README "Key design points".
