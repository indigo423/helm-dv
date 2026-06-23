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

## 1. External (production, bring-your-own Postgres)

The chart provisions **no** datastore — your daemons connect to an existing
PostgreSQL, Kafka (and ClickHouse for flows). This is the default mode.

**1. Create a Secret with the DB password** (key `password`):

```bash
kubectl create secret generic deltav-db \
  --from-literal=password='<your-postgres-password>'
```

**2. Install, pointing at your backing services:**

```bash
helm install deltav deltav/deltav \
  --set global.kafka.bootstrapServers=my-kafka-bootstrap:9092 \
  --set global.postgres.host=my-postgres.db.svc \
  --set global.postgres.database=opennms \
  --set global.postgres.username=opennms \
  --set global.postgres.existingSecret=deltav-db
```

> `global.postgres.mode` defaults to `external`, so no `--set` for it is needed.
> The `db-init` schema migration runs as a `pre-install` hook against your Postgres.

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
