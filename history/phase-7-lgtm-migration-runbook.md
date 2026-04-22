# Phase 7 — LGTM Migration Runbook

Replace ECK (Elasticsearch + Kibana) with the Grafana **LGTM** stack:
**L**oki (logs), **G**rafana (UI), **T**empo (traces), and Prometheus (metrics —
we use plain Prometheus at PoC scale, not Mimir).

This runbook is **verified against the actual cluster state** on `Cyclone` as of
2026-04-19. Every resource name, port, ConfigMap key, and Service reference has
been checked. Do not substitute or abstract — apply as written.

> **Note on Jaeger — varies by host.** Jaeger was installed on the work
> `devajk01` host during Phase 6 (in the `observability` namespace, colocated
> with ECK) but was never replicated to the home `Cyclone` host. Step 2a
> (Jaeger teardown) is conditional: run it on hosts where a Jaeger Helm
> release exists, skip it where it doesn't. **Do not** use the presence of a
> `tracing` namespace as the indicator — Jaeger's namespace varies. Check with:
> ```bash
> helm list -A | grep -i jaeger
> ```
> If nothing is returned, skip Step 2a and move to Step 2b.

---

## Verified cluster baseline

Before starting, the following are confirmed as-is on the `Cyclone` host. The
`devajk01` host is expected to match on these resources (same manifests were
applied); differences between hosts are called out where they exist (e.g.,
Jaeger in Step 2a).

| Resource | Name | Namespace |
|---|---|---|
| Gateway Deployment | `otel-collector-gateway` | `observability` |
| Gateway container name (inside pod) | `otel-collector` | — |
| Gateway ServiceAccount | `otel-collector-gateway` | `observability` |
| Gateway ConfigMap | `otel-collector-gateway-config` | `observability` |
| Gateway ConfigMap key | `config.yaml` | — |
| Gateway Service | `otel-collector-gateway` | `observability` |
| DaemonSet | `otel-collector-daemonset` | `observability` |
| DaemonSet ConfigMap | `otel-collector-daemonset-config` | `observability` |
| DaemonSet Service | `otel-collector-daemonset` | `observability` |
| Gateway pod label | `app=otel-collector-gateway` | — |
| ES credentials secret (to remove) | `otel-es-credentials` | `observability` |
| ES user secret (to remove) | `elasticsearch-es-elastic-user` | `observability` |
| OTel collector image | `otel/opentelemetry-collector-contrib:0.123.0` | — |
| ECK operator release | `elastic-operator` | `elastic-system` |
| ECK operator chart | `eck-operator-3.3.2` | — |

**Metrics port choice:** OTel Collector's internal telemetry metrics will be
exposed on **port 8888**, the OTel standard. (Flatnotes has been moved off
8888 to free it — standing on convention for the 3am rule.)

---

## What we are building

**End state:**

```
sensor-producer ──┐
mqtt-bridge       ├──► otel-collector-daemonset ──► otel-collector-gateway ──┬──► Tempo       (traces)
event-consumer ───┘                                                          ├──► Loki        (logs)
traefik ────────────────────────────────► otel-collector-gateway ────────────┤
                                                                             └──► Prometheus  (app metrics
                                                                                   via remote-write)

kubelet, node-exporter, kube-state-metrics, ─── scraped via Prometheus Operator ──► Prometheus
otel-collector-gateway :8888 (PodMonitor),
Traefik, Vault (later, deferred)

Grafana ──► Prometheus, Loki, Tempo (as datasources, provisioned as code)
        └► Dashboards: kube-prometheus-stack defaults + seven custom sensor panels
```

**Access:**

| Service | URL | Login |
|---|---|---|
| Grafana | `https://grafana.test` | `admin` / from Vault `secret/observability/grafana` |
| Prometheus | `http://<HOST>:9090` (via port-forward) | — |
| Alertmanager | `http://<HOST>:9093` (via port-forward) | — |
| Loki | not exposed — accessed only via Grafana | — |
| Tempo | not exposed — accessed only via Grafana | — |

Where `<HOST>` is:
- `localhost` if your cluster and browser are on the same machine
- `<SERVER_IP>` if the cluster runs on a dedicated Linux server and your
  browser is on a separate workstation

Grafana is the primary UI. Prometheus and Alertmanager UIs are not ingressed
via Traefik but are reachable from a browser using the
`kubectl port-forward` + `--network host` pattern already established for
Vault (see the `pf-vault` alias in `poc-toolkit.zsh`). The forwarded port binds
to all interfaces, so it's reachable from both the host itself and any remote
machine with network access. Loki and Tempo are cluster-internal only — use
Grafana Explore to query them.

### Retention policy

The PoC runs inside k3d on the host's `/var` partition, and k3d's local-path
provisioner does **not enforce PVC sizes** — the `5Gi` on each PVC is a
reservation, not a limit. Unbounded growth in any store will fill the host
disk. Retention is therefore the real safety mechanism, not storage sizing.

| Store | Retention | Set in | Typical steady-state size |
|---|---|---|---|
| Prometheus | 72h | `kube-prometheus-stack-values.yaml` → `prometheus.prometheusSpec.retention` | ~4 GB at 147k series |
| Loki | 2h | `loki-values.yaml` → `loki.limits_config.retention_period` + `loki.compactor.retention_enabled: true` | typically under 500 MB |
| Tempo | 2h | `tempo-values.yaml` → `tempo.retention` | typically under 1 GB |

**Rationale.** Logs and traces are the highest-volume stores and the
correlation targets for each other — they should share a retention window
so both are queryable when drilling into an issue. 2h matches the old ECK
`poc-2h-delete` ILM policy. Prometheus gets 72h because its per-byte
efficiency is very high (gorilla/XOR compression lands around 2 bytes per
sample), so three days of context is effectively free on disk — and the
kps default dashboards assume windows like 6h and 24h, which want to read
more than 2h of history to be useful.

**This is PoC behavior, not a pattern to carry forward.** Production AKS
will have longer retention backed by Thanos + Azure Blob for metrics and
object-storage-backed Loki/Tempo for logs and traces.

> **Retention verification timing note.** Loki's compactor runs on
> ~5-minute cycles. Immediately after `helm upgrade` or a fresh install,
> the compactor container will be running but will not have completed a
> full retention evaluation yet. Wait 5-10 minutes before expecting to see
> `mark file created` entries or deletion activity in
> `kubectl logs -n observability -l app.kubernetes.io/name=loki | grep
> compactor`. Tempo's compactor behaves similarly — blocks older than
> `block_retention` are dropped within ~30 minutes of the retention value
> taking effect. Prometheus enforces its retention flag immediately but
> the effect is only visible after the first tombstone cycle (typically
> every 2h).

### Chart version pinning

Every `helm upgrade --install` command in this runbook uses an explicit
`--version` flag. The pinned versions are:

| Chart | Version | App version | Source |
|---|---|---|---|
| kube-prometheus-stack | 83.6.0 | Prometheus v3.11.2, Grafana 12.4.3, Operator v0.90.1 | `prometheus-community` |
| loki | 6.55.0 | 3.6.7 | `grafana` |
| tempo | 1.24.4 | 2.9.0 | `grafana` |

These are the versions the runbook was verified against. Future versions
may introduce schema changes to values files, renamed fields in CRDs, or
changed defaults that break this runbook's assumptions. Upgrading is a
deliberate action, not a side effect of running the install commands.

**To upgrade a chart later:** check the chart's CHANGELOG for breaking
changes, update the `--version` pin here, update the corresponding
`*-values.yaml` file if the schema changed, run the upgrade on a test
cluster first, then update the Versions table in `CONTEXT.md`. Commit the
runbook, values file, and CONTEXT.md together in a single change so future
rebuilds stay coherent.

**If you see `Error: UPGRADE FAILED: ... schema validation failed` on a
`helm upgrade`,** this is the versioning discipline catching a values file
that's out of sync with the chart — not a runbook bug. Reconcile values
and chart versions before retrying.

---

## Pre-flight

### P1 — Confirm the starting state

```bash
# Current ECK + gateway state
kubectl get pods -n observability
# Expect: elasticsearch-es-default-0, kibana-kb-*, otel-collector-daemonset (x3), otel-collector-gateway

# No tracing namespace — confirmed
kubectl get ns | grep tracing || echo "no tracing namespace — skip Jaeger teardown"

# Sensor pipeline still producing telemetry
kubectl get pods -n sensor-dev
# Expect: sensor-producer, mqtt-bridge, event-consumer all 2/2 Running

# Current Helm releases
helm list -A
# Expect to see: elastic-operator (to be removed), cert-manager, traefik, vault, gitea, argocd, reloader
```

### P2 — Back up what we might want later

```bash
mkdir -p ${POC_DIR}/documentation/archive/phase7-predecommission

# Export Kibana saved objects one last time
ES_PASS=$(kubectl get secret elasticsearch-es-elastic-user \
  -n observability -o jsonpath='{.data.elastic}' | base64 -d | tr -d '\r\n')

curl -sk -u "elastic:${ES_PASS}" \
  -X POST "https://kibana.test/api/saved_objects/_export" \
  -H "kbn-xsrf: true" -H "Content-Type: application/json" \
  -d '{"type":["dashboard","lens","search","index-pattern"]}' \
  > ${POC_DIR}/documentation/archive/phase7-predecommission/kibana-final-export.ndjson

# Snapshot the current gateway ConfigMap and Deployment
kubectl get configmap otel-collector-gateway-config -n observability -o yaml \
  > ${POC_DIR}/documentation/archive/phase7-predecommission/otel-collector-gateway-config-pre-phase7.yaml

kubectl get deployment otel-collector-gateway -n observability -o yaml \
  > ${POC_DIR}/documentation/archive/phase7-predecommission/otel-collector-gateway-deploy-pre-phase7.yaml

# Snapshot the current Service
kubectl get service otel-collector-gateway -n observability -o yaml \
  > ${POC_DIR}/documentation/archive/phase7-predecommission/otel-collector-gateway-svc-pre-phase7.yaml
```

### P3 — Add Helm repositories

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### P4 — Ensure Vault port-forward is active

Step 4 (ECK credential cleanup) and Step 6 (Grafana admin credential) both
invoke the `vault` CLI. Vault is not exposed via Traefik in the PoC — it's
reached through a local port-forward. This needs to be running in a dedicated
terminal tab for the duration of Phase 7.

> **Recommended: use a terminal multiplexer.** Port-forwards need to stay open
> for the full session, and losing an SSH connection kills them. `rebuild-runbook.md`
> has a *Terminal multiplexer (recommended)* section that walks through tmux
> and GNU Screen setup, including a suggested window layout for a PoC build
> session. Worth 60 seconds to set up if you haven't already.

In a dedicated terminal (ideally a tmux/screen window):

```bash
pf-vault
```

Leave that terminal running. Verify Vault is reachable from your working
terminal before proceeding:

```bash
docker run --rm \
  --network host \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  -e VAULT_TOKEN="$(cat ${POC_DIR}/vault/root-token | tr -d '\r\n')" \
  devops-toolkit:latest vault status
```

Expected output includes `Sealed: false` and version info.
- If you see `connection refused`: `pf-vault` isn't running.
- If you see `Vault is sealed`: run `poc-start` to unseal.

> **Why an explicit `docker run` instead of the `vault` alias?** The bare
> `vault` alias in `poc-toolkit.zsh` mounts `${POC_DIR}/vault` at `/root/.vault`
> inside the container, which the Vault CLI expects to be a token-helper file,
> not a directory — causing `failed to get token helper: read /root/.vault:
> is a directory`. The explicit `docker run` form below sets `VAULT_TOKEN` and
> `VAULT_ADDR` as env vars directly, matching the pattern used in
> `rebuild-runbook.md`. Use this exact form for all Vault operations in
> Phase 7. This also means the runbook doesn't require the toolkit zsh aliases
> to be sourced — it works from a fresh clone of the repo.

---

## Part A — Pause telemetry, decommission ECK

The OTel gateway is the only thing writing to Elasticsearch. We pause it first
(send telemetry to the `debug` exporter only) so ECK can be torn down without
the gateway logging a wall of export errors.

### 1 — Apply interim "paused" gateway config

Create `manifests/otel-collector-gateway-config-phase7-interim.yaml`:

```bash
cat > ${POC_DIR}/manifests/otel-collector-gateway-config-phase7-interim.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-gateway-config
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      batch:
        timeout: 5s
        send_batch_size: 1024
      memory_limiter:
        check_interval: 5s
        limit_mib: 200
        spike_limit_mib: 50
    exporters:
      debug:
        verbosity: basic
    service:
      telemetry:
        logs:
          level: warn
      pipelines:
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [debug]
        logs:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [debug]
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [debug]
EOF
```

Apply it, and also remove the `ES_PASSWORD` env var from the Deployment so the
pod doesn't crash if the secret disappears before we redeploy in Part C:

```bash
kubectl apply -f /work/otel-collector-gateway-config-phase7-interim.yaml

# Strip the ES_PASSWORD env var
kubectl patch deployment otel-collector-gateway -n observability \
  --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/containers/0/env"}]'

kubectl rollout status deployment otel-collector-gateway -n observability
kubectl logs -n observability -l app=otel-collector-gateway --tail=30
# Expect: collector starts, exports traces/logs/metrics to debug. No errors.
```

At this point no data is being written anywhere — just logged to the collector's
stdout. Safe to tear down ECK.

### 2a — Uninstall Jaeger (conditional — skip if no Jaeger release found)

Run this step only on hosts where Jaeger was deployed during Phase 6. Jaeger's
namespace varies by host — it is **not** reliable to check for a `tracing`
namespace. Phase 6 runbooks varied: `devajk01` installed Jaeger into the
`observability` namespace alongside ECK; another cluster might use `tracing`
or something else. Always locate the release by name first.

**Discover the Helm release:**

```bash
helm list -A | grep -i jaeger
```

- If that returns nothing, Jaeger is not installed on this host. **Skip to Step 2b.**
- If it returns a release, note both the **release name** (usually `jaeger`)
  and the **namespace** in the output. Use those values in place of
  `<JAEGER_NS>` below.

**Teardown (replace `<JAEGER_NS>` with the namespace from above):**

```bash
JAEGER_NS=<observed-namespace>    # e.g., observability, tracing

# List what's currently there so you know what should be gone after teardown
kubectl get all -n ${JAEGER_NS} | grep -i jaeger
kubectl get ingressroute -n ${JAEGER_NS} | grep -i jaeger
kubectl get certificate -n ${JAEGER_NS} 2>/dev/null | grep -i jaeger

# Uninstall the Helm release — this removes the Deployment, ReplicaSet, Pod,
# Service, and the Helm release secret. It does NOT remove manually-applied
# IngressRoutes or Certificates (those were applied separately in Phase 6).
helm uninstall jaeger -n ${JAEGER_NS}

# Remove the manually-applied IngressRoute
kubectl delete ingressroute jaeger -n ${JAEGER_NS} 2>/dev/null || true

# Remove the Certificate (cert-manager auto-removes the backing TLS secret)
kubectl delete certificate jaeger-tls -n ${JAEGER_NS} 2>/dev/null || true

# Belt-and-suspenders in case the secret lingers
kubectl delete secret jaeger-tls -n ${JAEGER_NS} 2>/dev/null || true

# Remove any Jaeger PVCs (all-in-one defaults to in-memory, but some chart
# configs use a badger PVC for persistence — safe to attempt)
kubectl get pvc -n ${JAEGER_NS} | grep -i jaeger
kubectl delete pvc -l app.kubernetes.io/name=jaeger -n ${JAEGER_NS} 2>/dev/null || true

# If Jaeger was in its own dedicated namespace, remove the namespace.
# Skip this if ${JAEGER_NS} is shared with other workloads (e.g., observability).
if [ "${JAEGER_NS}" != "observability" ] && [ "${JAEGER_NS}" != "default" ]; then
  kubectl delete namespace ${JAEGER_NS}
fi
```

**Verify:**

```bash
kubectl get all -n ${JAEGER_NS} 2>/dev/null | grep -i jaeger
helm list -A | grep -i jaeger
kubectl get ingressroute -A | grep -i jaeger
kubectl get certificate -A 2>/dev/null | grep -i jaeger
```

All four should return empty output.

**Note:** Phase 6 added a Jaeger exporter to the OTel gateway config. That
exporter reference was already removed in Step 1 when we replaced the gateway
ConfigMap with the interim debug-only config — so no additional gateway config
work is needed here.

### 2b — Uninstall Kibana and Elasticsearch CRs

```bash
# Delete CR instances (ECK operator owns them)
kubectl delete kibana --all -n observability
kubectl delete elasticsearch --all -n observability

# Wait for dependent pods to terminate
kubectl get pods -n observability -w
# Ctrl-C once kibana-kb-* and elasticsearch-es-default-0 are gone

# PVCs don't get garbage-collected by CR deletion — remove explicitly
kubectl delete pvc -n observability -l common.k8s.elastic.co/type=elasticsearch

# Discover Kibana-related IngressRoutes, Certificates, and TLS secrets.
# These were applied manually in Phase 2 and are NOT owned by the Kibana CR,
# so deleting the CR does not clean them up. Inspect before deleting:
kubectl get ingressroute -n observability
kubectl get certificate -n observability
kubectl get secret -n observability | grep -i kibana

# Remove the Kibana IngressRoute
kubectl delete ingressroute kibana -n observability 2>/dev/null || true

# Remove the Kibana Certificate — cert-manager usually auto-removes the
# backing TLS secret when its Certificate is deleted
kubectl delete certificate kibana-tls -n observability 2>/dev/null || true

# Belt-and-suspenders in case the secret lingers
kubectl delete secret kibana-tls -n observability 2>/dev/null || true

# If your cluster used different names, substitute them in the commands above.
```

### 3 — Uninstall the ECK operator

```bash
helm uninstall elastic-operator -n elastic-system
kubectl delete namespace elastic-system

# Remove the CRDs so a future re-install isn't polluted.
# Note: cannot use `xargs kubectl delete` because the `kubectl` alias runs
# each invocation in a container — xargs spawns a subshell that doesn't
# inherit zsh aliases. Use an explicit for-loop instead.
# Also note: `tr -d '\r'` is required because the kubectl alias emits output
# with CRLF line endings; without stripping \r, each name in the for-loop
# gets a trailing carriage return and `kubectl delete` fails with NotFound.
for crd in $(kubectl get crd -o name | grep elastic.co | tr -d '\r'); do
  kubectl delete "$crd"
done

# Remove any leftover cluster-scoped ECK webhook configurations. Stale
# webhooks pointing at a gone service can block resource creation later.
for wh in $(kubectl get validatingwebhookconfigurations -o name | grep -i elastic | tr -d '\r'); do
  kubectl delete "$wh"
done
for wh in $(kubectl get mutatingwebhookconfigurations -o name | grep -i elastic | tr -d '\r'); do
  kubectl delete "$wh"
done
```

### 4 — Clean up ES credentials from the cluster and Vault

> **Requires `pf-vault` running in a separate terminal** (see Pre-flight P4).
> Uses explicit `docker run` for the vault invocation — see P4 for rationale.

```bash
# Kubernetes secrets
kubectl delete secret otel-es-credentials -n observability 2>/dev/null || true
kubectl delete secret elasticsearch-es-elastic-user -n observability 2>/dev/null || true

# Vault path (optional — can leave it, the ADR rationale notes this)
docker run --rm \
  --network host \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  -e VAULT_TOKEN="$(cat ${POC_DIR}/vault/root-token | tr -d '\r\n')" \
  devops-toolkit:latest \
  vault kv delete secret/observability/elasticsearch 2>/dev/null || true
```

### 5 — Verify demolition

```bash
kubectl get all -n observability
# Expect: only otel-collector-daemonset (DaemonSet, Service, ConfigMap) and
# otel-collector-gateway (Deployment, Service) remain

kubectl get pvc -n observability
# Expect: empty (PVCs removed in step 2)

kubectl get ns | grep elastic
# Expect: no elastic-system namespace

helm list -A | grep -E 'elastic|kibana'
# Expect: no matches
```

Namespace should be quiet. Move on to Part B.

---

## Part B — Install Prometheus, Loki, Tempo, Grafana

### 6 — Create Grafana admin credential in Vault and Kubernetes

> **Requires `pf-vault` running in a separate terminal** (see Pre-flight P4).
> Uses explicit `docker run` for the vault invocation — see P4 for rationale.
> The `vault kv put` is the authoritative store for the Grafana admin password;
> the Kubernetes secret is a derived copy that the Grafana Helm chart consumes
> at pod startup.

```bash
GRAFANA_PASS=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)

docker run --rm \
  --network host \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  -e VAULT_TOKEN="$(cat ${POC_DIR}/vault/root-token | tr -d '\r\n')" \
  devops-toolkit:latest \
  vault kv put secret/observability/grafana \
    username=admin \
    password="${GRAFANA_PASS}"

# The kubectl alias runs in a container, so piping two kubectl calls would
# cause a name conflict (see CONTEXT.md critical gotchas). Write to a file
# and apply separately.
#
# Path convention: ${POC_DIR}/tmp/ is mounted at /tmp/poc/ inside the toolkit
# container (via TOOLKIT_MOUNTS in poc-toolkit.zsh). The host-side redirect
# uses the host path; the kubectl invocation inside the container uses the
# container path.
kubectl create secret generic grafana-admin \
  --namespace observability \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="${GRAFANA_PASS}" \
  --dry-run=client -o yaml > ${POC_DIR}/tmp/grafana-admin-secret.yaml

kubectl apply -f /tmp/poc/grafana-admin-secret.yaml

rm ${POC_DIR}/tmp/grafana-admin-secret.yaml
```

### 7 — Install kube-prometheus-stack

Create `manifests/kube-prometheus-stack-values.yaml`:

```bash
cat > ${POC_DIR}/manifests/kube-prometheus-stack-values.yaml <<'EOF'
# kube-prometheus-stack values — PoC scale
# Upstream: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack

fullnameOverride: kps

prometheus:
  prometheusSpec:
    # 72h retention for PoC disk discipline. At ~147k active series and
    # typical kps scrape cadence this lands around 4 GB on disk. 72h gives
    # three days of context for investigating "when did this start"
    # questions — enough for the kps default dashboards (which default to
    # 6h / 24h windows) to remain useful, without letting Prom grow
    # unbounded. Production AKS will be longer, backed by Thanos.
    retention: 72h
    # Required for OTel gateway's prometheusremotewrite exporter
    enableRemoteWriteReceiver: true
    # Discover ServiceMonitors and PodMonitors in any namespace, any label
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    probeSelectorNilUsesHelmValues: false
    resources:
      requests: { cpu: 100m, memory: 512Mi }
      limits:   { cpu: 1,    memory: 2Gi  }
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources: { requests: { storage: 5Gi } }

alertmanager:
  # Kept as the unified notification backend. Grafana Alerting (below) sends
  # its alerts here, and PrometheusRule CRDs deliver here natively. One
  # Alertmanager, one set of silences, one set of notification policies.
  enabled: true
  alertmanagerSpec:
    resources:
      requests: { cpu: 10m,  memory: 32Mi }
      limits:   { cpu: 100m, memory: 128Mi }

grafana:
  enabled: true
  admin:
    existingSecret: grafana-admin
    userKey: admin-user
    passwordKey: admin-password
  persistence:
    enabled: true
    size: 1Gi
  service:
    type: ClusterIP
  # Unified alerting (Grafana 8+). Grafana-managed alert rules and
  # PrometheusRule-originated alerts both flow to the kube-prometheus-stack
  # Alertmanager. Grafana's Alerting UI shows rules from both sources in
  # one unified view.
  # See manifests/alerts/README.md for authoring patterns.
  grafana.ini:
    unified_alerting:
      enabled: true
    alerting:
      enabled: false   # legacy (pre-Grafana-8) alerting, off
  sidecar:
    dashboards:
      enabled: true
      searchNamespace: ALL
      label: grafana_dashboard
      labelValue: "1"
    datasources:
      enabled: true
      searchNamespace: ALL
      label: grafana_datasource
      labelValue: "1"
    # Sidecar for Grafana-provisioned alert rule ConfigMaps. ConfigMaps
    # labeled grafana_alert=1 are auto-loaded — no pod restart needed.
    alerts:
      enabled: true
      searchNamespace: ALL
      label: grafana_alert
      labelValue: "1"

nodeExporter:
  enabled: true

kubeStateMetrics:
  enabled: true

defaultRules:
  create: true

# k3d doesn't expose these control-plane ports to the Prometheus scraper
kubeControllerManager: { enabled: false }
kubeEtcd:              { enabled: false }
kubeScheduler:         { enabled: false }
kubeProxy:             { enabled: false }
EOF
```

Install:

```bash
helm upgrade --install kps prometheus-community/kube-prometheus-stack \
  --version 83.6.0 \
  --namespace observability \
  --values /work/kube-prometheus-stack-values.yaml \
  --wait --timeout 10m

# Verify pods — use two checks because the Grafana subchart doesn't apply
# the `release=kps` label that the other kps components do.
kubectl get pods -n observability -l release=kps
kubectl get pods -n observability -l app.kubernetes.io/name=grafana
```

Wait for all pods Running. Then verify the actual service names the chart
produced (the runbook's next steps reference these — if the names differ in a
future chart version, the datasource and OTel exporter configs must match
whatever is actually in the cluster):

```bash
# Same caveat: Grafana's Service isn't labeled release=kps, so check it
# separately. The first command lists Alertmanager, kube-state-metrics,
# Operator, Prometheus, and node-exporter. The second lists Grafana.
kubectl get svc -n observability -l release=kps
kubectl get svc -n observability -l app.kubernetes.io/name=grafana

# Expected services across both:
#   kps-grafana          (ClusterIP, port 80)
#   kps-prometheus       (ClusterIP, port 9090 — plus 8080)
#   kps-alertmanager     (ClusterIP, port 9093 — plus 8080)
#   kps-operator         (ClusterIP, port 443)
#   kps-kube-state-metrics
#   kps-prometheus-node-exporter
```

**⚠ Save the exact Prometheus service name for Step 10 and Step 12.** It's
typically `kps-prometheus`. Confirm with:

```bash
kubectl get svc -n observability -o name | grep -i prometheus | grep -v operator
```

### 8 — Install Loki

Create `manifests/loki-values.yaml`:

```bash
cat > ${POC_DIR}/manifests/loki-values.yaml <<'EOF'
# Loki values — single-binary, filesystem
# Upstream: https://github.com/grafana/loki/tree/main/production/helm/loki

deploymentMode: SingleBinary

loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: index_
          period: 24h
  limits_config:
    allow_structured_metadata: true
    volume_enabled: true
    # 2h retention for PoC disk discipline. Logs are the highest-volume
    # store (body + structured metadata per line) and bind-mounted onto the
    # host's /var partition via k3d's local-path provisioner, so "PVC
    # size" is a reservation, not a limit — unbounded growth can fill the
    # host disk. 2h matches the old ECK poc-2h-delete ILM policy.
    retention_period: 2h
  # Retention is ENFORCED by the compactor. Without retention_enabled=true,
  # the retention_period above is documentation only and Loki will keep
  # data forever. Compaction runs every 10m by default.
  compactor:
    retention_enabled: true
    delete_request_store: filesystem
  ruler:
    enable_api: false

singleBinary:
  replicas: 1
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { cpu: 1,    memory: 1Gi  }
  persistence:
    enabled: true
    size: 5Gi

# Disable scalable-topology components
read:    { replicas: 0 }
write:   { replicas: 0 }
backend: { replicas: 0 }

# Don't need these for PoC
chunksCache:  { enabled: false }
resultsCache: { enabled: false }
gateway:      { enabled: false }

test:        { enabled: false }
lokiCanary:  { enabled: false }

monitoring:
  serviceMonitor:
    enabled: true
    labels: { release: kps }
  selfMonitoring:
    enabled: false
    grafanaAgent:
      installOperator: false
  lokiCanary:
    enabled: false
EOF
```

Install:

```bash
helm upgrade --install loki grafana/loki \
  --version 6.55.0 \
  --namespace observability \
  --values /work/loki-values.yaml \
  --wait --timeout 10m

kubectl get pods -n observability -l app.kubernetes.io/name=loki
kubectl logs -n observability -l app.kubernetes.io/name=loki --tail=30

# Find the actual Loki service name — the gateway is disabled, so it's typically "loki"
kubectl get svc -n observability -l app.kubernetes.io/name=loki
```

**⚠ Save the Loki service name for Step 10 and Step 12.** With `gateway.enabled: false`
the service is typically `loki` on port 3100.

### 9 — Install Tempo

Create `manifests/tempo-values.yaml`:

```bash
cat > ${POC_DIR}/manifests/tempo-values.yaml <<'EOF'
# Tempo values — monolithic, filesystem
# Upstream: https://github.com/grafana/helm-charts/tree/main/charts/tempo

persistence:
  enabled: true
  size: 5Gi
resources:
  limits:
    cpu: 1
    memory: 1Gi
  requests:
    cpu: 100m
    memory: 256Mi
serviceMonitor:
  enabled: true
  labels:
    release: kps
tempo:
  # Metrics-generator: derives Prometheus metrics from spans as they flow
  # through Tempo. Enables the Panel 1 (p95 latency) and Panel 4 (error rate)
  # queries that read traces_spanmetrics_* metrics from Prometheus.
  metricsGenerator:
    enabled: true
    # NOTE: The Prometheus URL here references the service name from Step 7.
    # If your kps Prometheus service is named differently, update this line.
    remoteWriteUrl: http://kps-prometheus.observability.svc.cluster.local:9090/api/v1/write

  # Processors MUST be enabled via per-tenant overrides — the global
  # `metricsGenerator.enabled: true` flag installs and configures the
  # component, but without processors listed here it runs idle and
  # produces no metrics. This is a silent failure mode: no errors in
  # Tempo logs, `helm get values` shows correct-looking config, but
  # traces_spanmetrics_* metrics never appear in Prometheus and Panels
  # 1 and 4 stay empty.
  #
  # - service-graphs: service-to-service call metrics (feeds Grafana's
  #   Service Map view on the Tempo datasource).
  # - span-metrics: latency histograms and call-count counters
  #   (feeds traces_spanmetrics_latency_bucket and
  #   traces_spanmetrics_calls_total in Prometheus).
  overrides:
    defaults:
      metrics_generator:
        processors:
          - service-graphs
          - span-metrics

  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
  # 2h retention for PoC disk discipline. Tempo's block_retention is set by
  # this value; the compactor runs continuously and deletes blocks older
  # than this threshold. Matches Loki at 2h — logs and traces correlate by
  # trace_id and should be queryable over the same window.
  retention: 2h
  storage:
    trace:
      backend: local
      local:
        path: /var/tempo/traces
      wal:
        path: /var/tempo/wal
EOF
```

> **⚠ Before applying:** confirm the Prometheus service name matches the
> `remoteWriteUrl` above. Run:
> ```bash
> kubectl get svc -n observability -o name | grep -i prometheus | grep -v operator
> ```
> If the service is not `kps-prometheus`, edit the
> `remoteWriteUrl` in `tempo-values.yaml` before installing.

Install:

```bash
helm upgrade --install tempo grafana/tempo \
  --version 1.24.4 \
  --namespace observability \
  --values /work/tempo-values.yaml \
  --wait --timeout 10m

kubectl get pods -n observability -l app.kubernetes.io/name=tempo
kubectl logs -n observability -l app.kubernetes.io/name=tempo --tail=30

# Get the actual Tempo service name
kubectl get svc -n observability -l app.kubernetes.io/name=tempo
```

**⚠ Save the Tempo service name for Step 10 and Step 12.** Typically `tempo`
on port 3200 (query, used by the Grafana datasource) and 4317 (OTLP gRPC,
used by the OTel gateway to push traces in). Confirm both ports exist.

**Verify metrics-generator is actually producing metrics.** Do NOT rely on
grepping Tempo logs — Tempo 2.9 does not log at INFO level when the generator
is healthy, so silence is not a diagnostic signal. The reliable check is to
ask Prometheus directly what metric names exist.

Wait approximately 5 minutes after Tempo starts to allow the generator to
warm up and observe enough span traffic, then:

```bash
kubectl port-forward -n observability svc/kps-prometheus 9090:9090 &
sleep 2

curl -s 'http://localhost:9090/api/v1/label/__name__/values' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join([m for m in d['data'] if 'spanmetric' in m.lower() or 'servicegraph' in m.lower()]))"

kill %1 2>/dev/null
```

Expected output — metric names beginning with `traces_spanmetrics_` and
`traces_service_graph_`:

```
traces_service_graph_request_client_seconds_bucket
traces_service_graph_request_client_seconds_count
traces_service_graph_request_client_seconds_sum
traces_service_graph_request_server_seconds_bucket
traces_service_graph_request_server_seconds_count
traces_service_graph_request_server_seconds_sum
traces_service_graph_request_total
traces_spanmetrics_calls_total
traces_spanmetrics_latency_bucket
traces_spanmetrics_latency_count
traces_spanmetrics_latency_sum
traces_spanmetrics_size_total
```

If none of these appear after 5+ minutes of span traffic, see
Troubleshooting: *Tempo metrics-generator produces no metrics*.

### 10 — Provision Grafana datasources

> **Before writing this file**, confirm the actual service names for Prometheus,
> Loki, and Tempo from Steps 7-9. The YAML below uses the most likely names —
> adjust if your cluster produced different names.

Create `manifests/grafana-datasources.yaml`:

```bash
cat > ${POC_DIR}/manifests/grafana-datasources.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources-lgtm
  namespace: observability
  labels:
    grafana_datasource: "1"
data:
  datasources.yaml: |-
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        uid: loki
        access: proxy
        # Update if your loki service is named differently
        url: http://loki.observability.svc.cluster.local:3100
        isDefault: false
        jsonData:
          derivedFields:
            # Match against the trace_id structured metadata label attached
            # automatically by the OTel SDK on every log record. This is more
            # reliable than regex-scanning the log body, which depends on
            # per-app logging conventions.
            #
            # Field-name gotcha: for label-based matches, `matcherType: label`
            # is the trigger, and `matcherRegex` is reinterpreted as the
            # *label name* (not a regex). The field names `type:` and `label:`
            # used in some older examples are silently ignored and the field
            # falls back to regex mode, producing 0% matches.
            - name: TraceID
              matcherType: label
              matcherRegex: trace_id
              url: '$${__value.raw}'
              datasourceUid: tempo
              urlDisplayLabel: View trace

      - name: Tempo
        type: tempo
        uid: tempo
        access: proxy
        # Update if your tempo service is named differently
        url: http://tempo.observability.svc.cluster.local:3200
        isDefault: false
        jsonData:
          tracesToLogsV2:
            datasourceUid: loki
            spanStartTimeShift: -1h
            spanEndTimeShift: 1h
            tags:
              - key: service.name
                value: service_name
            filterByTraceID: true
            filterBySpanID: false
          tracesToMetrics:
            datasourceUid: prometheus
            tags:
              - key: service.name
                value: service
          serviceMap:
            datasourceUid: prometheus
          nodeGraph:
            enabled: true
          search:
            hide: false
          lokiSearch:
            datasourceUid: loki

      # Alertmanager — used by Grafana's Alerting UI to display silences,
      # notification policies, contact points, and alert state. Grafana's
      # unified alerting (see grafana.ini block in kube-prometheus-stack-values.yaml)
      # sends its alerts to this same Alertmanager, so one instance handles
      # notifications from both PrometheusRule CRDs and Grafana-provisioned
      # alert rules.
      - name: Alertmanager
        type: alertmanager
        uid: alertmanager
        access: proxy
        # UPDATE if the kps Alertmanager service is named differently — verify with:
        #   kubectl get svc -n observability -l app.kubernetes.io/name=alertmanager
        url: http://kps-alertmanager.observability.svc.cluster.local:9093
        jsonData:
          implementation: prometheus
          handleGrafanaManagedAlerts: true
EOF
```

Apply:

```bash
kubectl apply -f /work/grafana-datasources.yaml

# Watch Grafana's sidecar pick up the new ConfigMap
kubectl logs -n observability -l app.kubernetes.io/name=grafana -c grafana-sc-datasources --tail=20
# Expect a line mentioning 'grafana-datasources-lgtm'
```

> **Verifying derived fields loaded correctly.** In Grafana Explore → Loki,
> run `{service_name="event-consumer"}` and expand any log line. The Fields
> list should show `TraceID` at **100%**. A reading of **0%** means the
> matcher isn't hitting — most commonly because `matcherType:` was misspelled
> or `matcherRegex:` holds a regex instead of the label name. Scroll to the
> bottom of the expanded panel — a **Links** section with a **View trace**
> button should appear; clicking it opens the correlated trace in Tempo.

### 11 — Expose Grafana via Traefik

Create `manifests/grafana-ingress.yaml`:

```bash
cat > ${POC_DIR}/manifests/grafana-ingress.yaml <<'EOF'
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: grafana
  namespace: observability
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`grafana.test`)
      kind: Rule
      services:
        - name: kps-grafana
          port: 80
  tls:
    secretName: grafana-tls
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: grafana-tls
  namespace: observability
spec:
  secretName: grafana-tls
  issuerRef:
    name: vault-issuer
    kind: ClusterIssuer
  dnsNames:
    - grafana.test
  commonName: grafana.test
EOF
```

> **⚠ Before applying:** confirm your ClusterIssuer name. The runbook assumes
> `vault-issuer` from Phase 1. Verify with:
> ```bash
> kubectl get clusterissuer
> ```
> Adjust the `issuerRef.name` if your issuer has a different name.

Apply:

```bash
kubectl apply -f /work/grafana-ingress.yaml

kubectl get certificate -n observability grafana-tls -w
# Wait for READY=True, Ctrl-C

# Add grafana.test to the Windows workstation hosts file → server IP
# Add grafana.test to the Linux host /etc/hosts → 127.0.0.1 if needed
```

Browser: `https://grafana.test` → login `admin` / `${GRAFANA_PASS}`.

In Grafana: **Connections → Data sources**. Four datasources should be listed:

- **Prometheus** — auto-provisioned by kube-prometheus-stack
- **Loki** — provisioned in Step 10
- **Tempo** — provisioned in Step 10
- **Alertmanager** — provisioned in Step 10 for Grafana Alerting

Click each and "Test" — all four must return green.

Then verify Grafana Alerting is operational: in the left nav, click
**Alerting → Alert rules**. You should see an empty rules list (no errors,
no rules yet — that's the intended state post-Phase-7).

**Do not proceed past this point if any datasource fails or the Alerting page
errors.** Every panel depends on the datasources working; future alert rule
authoring depends on the Alerting page being reachable.

---

## Part C — Rewire the OTel Gateway

### 12a — Rewrite the gateway Deployment

> This replaces the existing Deployment with a clean manifest. The ES env var
> is already removed (Step 1). This step adds the 8888 metrics port and ensures
> the manifest is committed to Git as the source of truth.

Create `manifests/otel-collector-gateway.yaml`:

```bash
cat > ${POC_DIR}/manifests/otel-collector-gateway.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector-gateway
  namespace: observability
  labels:
    app: otel-collector-gateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel-collector-gateway
  template:
    metadata:
      labels:
        app: otel-collector-gateway
    spec:
      serviceAccountName: otel-collector-gateway
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.123.0
          imagePullPolicy: IfNotPresent
          args:
            - --config=/conf/config.yaml
          ports:
            - containerPort: 4317
              name: otlp-grpc
              protocol: TCP
            - containerPort: 4318
              name: otlp-http
              protocol: TCP
            - containerPort: 8888
              name: metrics
              protocol: TCP
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          volumeMounts:
            - mountPath: /conf
              name: config
      volumes:
        - name: config
          configMap:
            name: otel-collector-gateway-config
EOF
```

### 12b — Rewrite the gateway Service

Create `manifests/otel-collector-gateway-service.yaml`:

```bash
cat > ${POC_DIR}/manifests/otel-collector-gateway-service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: otel-collector-gateway
  namespace: observability
  labels:
    app: otel-collector-gateway
spec:
  type: ClusterIP
  selector:
    app: otel-collector-gateway
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
    - name: otlp-http
      port: 4318
      targetPort: 4318
    - name: metrics
      port: 8888
      targetPort: 8888
EOF
```

### 12c — Write the real Phase 7 gateway ConfigMap

> **⚠ Before writing this file:** verify the exact service names and endpoints
> for Tempo, Loki, and Prometheus from Steps 7-9. The endpoints below assume
> the most likely names — replace with your actual values before applying.

Create `manifests/otel-collector-gateway-config.yaml`:

```bash
cat > ${POC_DIR}/manifests/otel-collector-gateway-config.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-gateway-config
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      batch:
        timeout: 5s
        send_batch_size: 1024
      memory_limiter:
        check_interval: 5s
        limit_mib: 200
        spike_limit_mib: 50
      # Rename service.name → service_name so Loki accepts it as a stream label
      # (Loki labels cannot contain dots)
      resource:
        attributes:
          - key: service_name
            from_attribute: service.name
            action: insert

    exporters:
      # Traces → Tempo (OTLP gRPC)
      otlp/tempo:
        endpoint: tempo.observability.svc.cluster.local:4317
        tls:
          insecure: true

      # Logs → Loki (OTLP HTTP, via Loki 3.x native /otlp endpoint)
      otlphttp/loki:
        endpoint: http://loki.observability.svc.cluster.local:3100/otlp
        tls:
          insecure: true

      # Metrics → Prometheus (remote-write)
      # UPDATE this endpoint to match the actual Prometheus service name
      # from Step 7, then rollout restart.
      prometheusremotewrite:
        endpoint: http://kps-prometheus.observability.svc.cluster.local:9090/api/v1/write
        tls:
          insecure: true
        resource_to_telemetry_conversion:
          enabled: true

      debug:
        verbosity: basic

    service:
      telemetry:
        logs:
          level: warn
        metrics:
          level: detailed
          # The `address:` form was deprecated in favor of the `readers:`
          # block which allows multiple metrics exporters, pull vs push, etc.
          # This is the forward-compatible form. Functionally identical —
          # the Prometheus endpoint is still at :8888/metrics.
          readers:
            - pull:
                exporter:
                  prometheus:
                    host: 0.0.0.0
                    port: 8888
      pipelines:
        traces:
          receivers:  [otlp]
          processors: [memory_limiter, resource, batch]
          exporters:  [otlp/tempo]
        logs:
          receivers:  [otlp]
          processors: [memory_limiter, resource, batch]
          exporters:  [otlphttp/loki]
        metrics:
          receivers:  [otlp]
          processors: [memory_limiter, resource, batch]
          exporters:  [prometheusremotewrite]
EOF
```

### 12d — Apply the three gateway manifests and restart

```bash
# Apply ConfigMap first — pod reads it on start
kubectl apply -f /work/otel-collector-gateway-config.yaml

# Apply Service (adds the metrics port)
kubectl apply -f /work/otel-collector-gateway-service.yaml

# Apply Deployment (adds the 8888 containerPort)
kubectl apply -f /work/otel-collector-gateway.yaml

kubectl rollout status deployment otel-collector-gateway -n observability

# Tail logs — expect "Everything is ready" or similar, no exporter errors
kubectl logs -n observability -l app=otel-collector-gateway --tail=50
```

Look for exporter-related errors in particular:
- `failed to push metrics to Prometheus` → Prometheus service name wrong
- `failed to push logs to Loki` → Loki service name wrong, or OTLP endpoint path wrong
- `failed to push traces to Tempo` → Tempo service name wrong or port 4317 not listening

If any appear, update the relevant endpoint in
`otel-collector-gateway-config.yaml`, re-apply, and re-restart.

### 13 — PodMonitor for the gateway's own telemetry

Create `manifests/otel-collector-gateway-podmonitor.yaml`:

```bash
cat > ${POC_DIR}/manifests/otel-collector-gateway-podmonitor.yaml <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: otel-collector-gateway
  namespace: observability
  labels:
    release: kps
spec:
  selector:
    matchLabels:
      app: otel-collector-gateway
  podMetricsEndpoints:
    - port: metrics
      interval: 30s
EOF
```

```bash
kubectl apply -f /work/otel-collector-gateway-podmonitor.yaml

# Verify Prometheus picked up the new target. Port-forward from the Linux host.
# --network host on the kubectl alias means port 9090 binds to all interfaces,
# so the port is reachable from both the host shell and the workstation browser.
kubectl port-forward -n observability svc/kps-prometheus 9090:9090 &
```

Check the `otel-collector-gateway` target is UP. Two ways:

- **From the workstation browser** (dedicated-server setup):
  Open `http://<SERVER_IP>:9090/targets` and find the `otel-collector-gateway` target.
- **From the workstation browser** (single-host setup, cluster runs locally):
  Open `http://localhost:9090/targets`.
- **From the Linux host shell** (either setup — works without a browser):
  ```bash
  curl -s http://localhost:9090/api/v1/targets \
    | jq '.data.activeTargets[] | select(.labels.job | test("otel"))'
  ```

When done, kill the port-forward:

```bash
kill %1 2>/dev/null
```

---

## Part D — Verify end to end

Do not skip any of these. Each is a natural checkpoint; if one fails, stop and
debug before moving on.

### 14 — Traces flowing into Tempo

In Grafana:
1. Explore → select **Tempo**
2. Query type: "Search"
3. Service Name dropdown — should list: `sensor-producer`, `mqtt-bridge`,
   `event-consumer`, `traefik`
4. Run with no filters — recent traces appear
5. Click any trace → waterfall opens with spans from all services

**If the dropdown is empty:** wait 60 seconds (first-trace delay), retry.
If still empty, check gateway logs for `otlp/tempo` export errors.

### 15 — Logs flowing into Loki

In Grafana:
1. Explore → select **Loki**
2. Click the **Label browser** button
3. `service_name` label should show values: `sensor-producer`, `mqtt-bridge`,
   `event-consumer`
4. Pick one, "Show logs"
5. Log lines appear

**If label browser is empty or shows no values:** check the OTel gateway's
`otlphttp/loki` endpoint, verify Loki is accepting OTLP (`kubectl logs -n
observability -l app.kubernetes.io/name=loki` should not show ingestion errors).

### 16 — Log → trace correlation works

In Grafana Loki Explore:
1. Run `{service_name="event-consumer"}`
2. Expand any log line
3. Look for a `TraceID` derived field with a "View trace" link
4. Click it → should open Tempo with the matching trace

**If no TraceID field appears:** the regex in the datasource doesn't match how
trace IDs are serialized in your log body. Inspect one raw log line — if the
format is `TraceId: abc...` (camel case, no quotes), the regex needs adjusting.
The regex `'"?[Tt]race[_-]?[Ii]d"?[:=]\s*"?([a-f0-9]{32})"?'` is defensive but
may miss edge cases.

### 17 — Metrics flowing into Prometheus

```bash
# Port-forward from the Linux host (not the workstation).
# Because kubectl runs with --network host, port 9090 binds to all interfaces
# and is reachable from both the host itself and the workstation browser.
kubectl port-forward -n observability svc/kps-prometheus 9090:9090 &
```

Open the Prometheus expression browser:

- **If running the cluster on your local workstation** (single-host setup):
  `http://localhost:9090`
- **If running the cluster on a dedicated Linux server** (as documented in CONTEXT.md):
  `http://<SERVER_IP>:9090` from the workstation browser

Run these queries in the expression browser:

- `up`
- `otelcol_exporter_sent_spans_total`
- `otelcol_exporter_sent_log_records_total`
- `kube_pod_info{namespace="sensor-dev"}`

All should return data.

Stop the port-forward when done:

```bash
kill %1 2>/dev/null
```

In Grafana: Explore → **Prometheus** → Metrics browser. Hundreds of metrics
should be available — this is the primary verification path going forward.
The direct Prometheus UI is useful for `/targets`, `/rules`, and `/status`
pages that Grafana doesn't expose, but day-to-day querying happens in Grafana.

### 18 — Default kps dashboards render with data

Grafana → Dashboards → Browse. Expand "General" → open **Kubernetes / Compute
Resources / Cluster**. CPU and memory panels populated.

If this dashboard works, your metrics pipeline is solid.

---

## Part E — Rebuild the Phase 5a dashboard

The seven Kibana panels, rebuilt as Grafana panels against Loki / Tempo /
Prometheus.

| # | Panel | Datasource | Query language |
|---|---|---|---|
| 1 | Service Latency Over Time | Prometheus (from Tempo metrics-gen) | PromQL |
| 2 | Event Throughput by Sensor | Loki | LogQL |
| 3 | Sensor Trend Distribution | Loki | LogQL |
| 4 | Error Span Rate | Prometheus (from Tempo metrics-gen) | PromQL |
| 5 | Trace Span Timeline | Tempo | TraceQL |
| 6 | Event Consumer Logs | Loki | LogQL |
| 7 | Cross-Service Log Correlation | Loki | LogQL |

### Background — Loki labels, structured metadata, and parsed fields

Loki distinguishes three places where label-like data lives, and query
syntax differs for each:

1. **Indexed stream labels** — used in `{...}` selectors, e.g.
   `{service_name="sensor-producer"}`. These are what Loki actually indexes.
   Loki's OTel ingester indexes only a small allowlist — `service_name`,
   `deployment_environment`, `severity_text`, `service_namespace`, and a
   few others. High cardinality here destroys Loki performance, which is
   why the list is short by design.

2. **Structured metadata** — per-log-line labels attached by the ingester
   from OTel resource attributes, but not indexed. Queryable via pipe
   stages after the stream selector, e.g.
   `{service_name="x"} | SensorId != ""`. **Most OTel log attributes
   (`SensorId`, `Trend`, `TraceId`, `Value`, `Unit`, `Delta`, etc.) land
   here, not in indexed labels.**

3. **Parsed fields** — extracted from the log body at query time via
   `| json` or `| logfmt`. Only relevant if the log body itself is in a
   parseable format. The sensor demo's log bodies are unstructured text
   (currently containing unrendered `{TraceId}`-style template
   placeholders), so `| json` will throw `JSONParserErr` on these logs.

To check whether a field is an indexed label or structured metadata:

```bash
kubectl run loki-probe --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 -n observability -- \
  curl -s 'http://loki.observability.svc.cluster.local:3100/loki/api/v1/labels'
```

Any field name in that list is indexed; anything else is structured metadata
(or doesn't exist at all). This distinction drives the structure of every
LogQL query below.

### Verify every query in Explore before building the dashboard

Testing each query in Explore first lets you confirm data shape before
committing to a panel. Some queries depend on data streams that need warmup
time (Tempo's metrics-generator takes ~5 minutes of span traffic after
startup). If a query returns nothing in Explore, the panel will be empty too.

**Panel 1 — Service Latency Over Time (PromQL, Prometheus):**
```promql
histogram_quantile(0.95,
  sum by (service, le) (
    rate(traces_spanmetrics_latency_bucket[5m])
  )
)
```

Returns one p95 latency line per service. Traefik typically dominates
(~200ms — wraps the whole request chain). Internal services are much faster.
If empty, see Troubleshooting: *Tempo metrics-generator produces no metrics*.

**Panel 2 — Event Throughput by Sensor (LogQL, Loki):**
```logql
sum by (SensorId) (
  count_over_time({service_name="sensor-producer"} | SensorId != "" [1m])
)
```

`SensorId` is structured metadata, not an indexed label — it must live in a
pipe-stage filter (`| SensorId != ""`), not the stream selector. Do NOT add
`| json` — the log body is not valid JSON.

**Panel 3 — Sensor Trend Distribution (LogQL, Loki, pie chart):**
```logql
sum by (Trend) (
  count_over_time({service_name="mqtt-bridge"} | Trend != "" [5m] offset 30s)
)
```

Same pattern as Panel 2. `Trend` is structured metadata. Explore renders this
as a time series; the pie visualization comes later when building the panel.

> **Why the `offset 30s`.** The 30-second offset shifts the query window
> back from "now" to avoid ingestion-lag noise on the trailing edge. Without
> it, individual trend slices can briefly disappear when the most recent
> log chunk hasn't flushed yet. Leave the pie's default `queryType: range`,
> `reduceOptions.calcs: [lastNotNull]`, and `reduceOptions.fields: ""` —
> this is Grafana's default for pie-of-Loki and it works as expected.

**Panel 4 — Error Span Rate (PromQL, Prometheus):**
```promql
sum by (service) (
  rate(traces_spanmetrics_calls_total{status_code="STATUS_CODE_ERROR"}[5m])
)
```

> **Expected behavior with a happy-path demo:** Panel 4 will appear empty
> or near-empty under normal operation. Any non-zero values are real errors
> (commonly Traefik serving a 4xx on a probe or malformed request). To
> demonstrate the panel with richer data, introduce deliberate errors via
> an env var scoped to `envs/dev` using the Phase 5b pattern (see the
> `BRIDGE_DELAY_MS` env var on mqtt-bridge as a reference implementation).

**Panel 5 — Trace Span Timeline (TraceQL, Tempo):** test by pasting a
real trace ID (32 hex chars, copied from any log line's `trace_id`
structured metadata) into a Tempo TraceQL query. The full waterfall should
render showing parent/child spans across all three services. In the dashboard
this will be fed by a `$trace_id` textbox variable — see the build
walkthrough below.

**Panel 6 — Event Consumer Logs (LogQL, Loki, Logs panel):**
```logql
{service_name="event-consumer"}
```

Stream selector only — no pipeline. Verify that expanding a log line shows a
**Links** section with a working **View trace** button (from the derived
field configured in Step 10).

**Panel 7 — Cross-Service Log Correlation (LogQL, Loki, Logs panel):**
```logql
{service_name=~"sensor-producer|mqtt-bridge|event-consumer"}
```

Interleaved log lines from all three services in time order. Each line's
trace ID link works independently — the correlation is a property of the
Loki datasource, not the query.

### Build-and-commit workflow

#### Part 1 — Create the dashboard shell

1. Grafana → **Dashboards** → **New** → **New dashboard**
2. Click the gear icon (top right) → **Settings**
3. **General** tab:
   - Title: `Sensor Demo — Observability Overview`
   - Description: `LGTM-stack demo dashboard: traces, logs, and metrics from the three-service sensor pipeline (sensor-producer → mqtt-bridge → event-consumer).`
   - Tags: `sensor-demo`, `lgtm`, `poc`
4. **Variables** tab → **Add variable**:
   - Type: `Textbox`
   - Name: `trace_id`
   - Label: `Trace ID`
   - Default value: (empty)
   - Click **Apply**
5. Top right: set time range to **Last 1 hour**, auto-refresh to **30s**
6. Click **Save dashboard** (required before panel JSON export works correctly)

#### Part 2 — Add panels

For each of the seven panels below: **+ Add panel** → **Add visualization** →
pick the viz type → select the datasource → paste the query → set the title
and unit.

| # | Title | Viz type | Datasource | Query | Notes |
|---|---|---|---|---|---|
| 1 | Service Latency (p95) | Time series | Prometheus | Panel 1 query above | Unit: seconds. Legend: `{{service}}` |
| 2 | Event Throughput by Sensor | Time series | Loki | Panel 2 query above | Legend: `{{SensorId}}` |
| 3 | Sensor Trend Distribution | Pie chart | Loki | Panel 3 query above (keep the `offset 30s`) | Keep default pie settings. Legend: `{{Trend}}` |
| 4 | Error Span Rate | Time series | Prometheus | Panel 4 query above | Unit: ops/sec. Legend: `{{service}}` |
| 5 | Trace Waterfall | Traces | Tempo | `${trace_id}` | Query type: TraceQL |
| 6 | Event Consumer Logs | Logs | Loki | Panel 6 query above | Panel options → Show time: on |
| 7 | Cross-Service Logs | Logs | Loki | Panel 7 query above | Panel options → Show time: on |

#### Part 3 — Suggested layout

The Grafana dashboard grid is 24 columns wide. A workable arrangement:

```
┌──────────────────────────────┬──────────────────────────────┐
│ Panel 1: Service Latency     │ Panel 4: Error Span Rate     │
│ (time series, 12 cols)       │ (time series, 12 cols)       │
├──────────┬───────────────────┼──────────────────────────────┤
│ P3: Trend│ Panel 2:          │ Panel 5: Trace Waterfall     │
│ (pie,    │ Event Throughput  │ (Traces panel, 12 cols)      │
│ 6 cols)  │ (time series,     │                              │
│          │ 6 cols)           │                              │
├──────────┴───────────────────┼──────────────────────────────┤
│ Panel 6: Event Consumer Logs │ Panel 7: Cross-Service Logs  │
│ (logs, 12 cols)              │ (logs, 12 cols)              │
└──────────────────────────────┴──────────────────────────────┘
```

Top row: headline metrics (latency and errors). Middle row: supporting
breakdowns alongside the on-demand trace waterfall. Bottom row: raw logs for
drill-down. Rearrange as preferred — layout is trivial to iterate later.

#### Part 4 — Verify the dashboard end-to-end

1. Save the dashboard.
2. Confirm every panel shows data (Panel 4 may be near-empty — see the
   expected-behavior note above).
3. Test Panel 5: copy a `trace_id` value from any log line in Panel 6 or
   Panel 7, paste it into the `trace_id` textbox at the top of the dashboard,
   and confirm Panel 5 renders the waterfall.
4. Test derived-field correlation from inside a dashboard panel: expand any
   log line in Panel 6 or 7, confirm the **View trace** link renders, click
   it, confirm the Tempo trace opens.

#### Part 5 — Export and provision as code

1. Dashboard settings (gear icon) → **JSON Model** → **Copy**.
2. Save to `manifests/grafana-dashboard-sensor-demo.yaml` wrapped in a ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-sensor-demo
  namespace: observability
  labels:
    grafana_dashboard: "1"
data:
  sensor-demo.json: |-
    <paste exported JSON here, indented 4 spaces>
```

3. Apply: `kubectl apply -f /work/grafana-dashboard-sensor-demo.yaml`
4. Grafana's dashboard sidecar hot-reloads the provisioned dashboard. The
   dashboard now persists across Grafana pod restarts and cluster rebuilds.

> **⚠ Indentation matters.** The exported JSON must be indented beneath
> `sensor-demo.json: |-` by exactly 4 spaces. `kubectl apply` will accept
> a malformed ConfigMap silently and the sidecar will ignore it.

---

## Part F — Clean up, commit, update docs

### 19 — Remove obsolete files

```bash
rm -v ${POC_DIR}/manifests/otel-collector-gateway-config-phase7-interim.yaml

# Move Phase 6 / ECK-era docs to archive
mv ${POC_DIR}/documentation/observability-setup.md \
   ${POC_DIR}/documentation/archive/phase7-predecommission/ 2>/dev/null || true

mv ${POC_DIR}/documentation/jaeger-runbook-phase6.md \
   ${POC_DIR}/documentation/archive/phase7-predecommission/ 2>/dev/null || true

# Retire the ECK-specific scripts
rm -v ${POC_DIR}/scripts/obs-init.sh 2>/dev/null || true
rm -v ${POC_DIR}/scripts/obs-ilm-init.sh 2>/dev/null || true
```

### 19a — Scaffold the alerts directory

Phase 7 wires up the Grafana Alerting capability (Step 7 values, Step 10
Alertmanager datasource). This step ensures the directory and README that
document the authoring convention exist on this host.

```bash
mkdir -p ${POC_DIR}/manifests/alerts

# Verify the README is present — it should have synced in from the repo if
# you're working from a clone that already has it. If missing, copy from
# wherever the canonical version lives.
ls -la ${POC_DIR}/manifests/alerts/README.md
```

No alert rules are written in Phase 7. The README explains the two
authoring patterns (PrometheusRule CRDs for metrics-only alerts, Grafana
alert rule ConfigMaps for cross-datasource alerts) and flags that a future
phase will produce the first working examples. See
`${POC_DIR}/manifests/alerts/README.md` for the full detail.

### 20 — Update workstation hosts files

- Windows workstation `C:\Windows\System32\drivers\etc\hosts`: remove `kibana.test`,
  add `grafana.test` (same server IP)
- Linux host `/etc/hosts`: same swap
- k3d node `/etc/hosts` via `coredns-patch.sh` — no change needed; CoreDNS
  rewrite handles `*.test` cluster-internally

### 21 — Update toolkit zsh helpers

Edit `~/.zshrc.d/poc-toolkit.zsh` (canonical copy lives at
`${POC_DIR}/documentation/poc-toolkit.zsh`):

**Remove** — no longer needed:

- `pf-es` alias (Elasticsearch is gone)
- `pf-kibana` alias (Kibana is gone)
- `es-pass` function (no ES credentials)

**Replace** `es-pass` with `grafana-pass`:

```zsh
grafana-pass() {
  # Retrieve Grafana admin password from k8s secret
  # Pulls directly from k8s — reliable, no ANSI encoding issues
  # For manual login use the Vault UI at http://127.0.0.1:8200
  kubectl get secret grafana-admin \
    -n observability \
    -o jsonpath='{.data.admin-password}' | base64 -d | tr -d '\r\n'
  echo
}
```

**Add** port-forward aliases for Prometheus and Alertmanager. These follow
the same `--network host` + `docker run` pattern as `pf-vault` so the bound
port is reachable from the workstation at `http://<SERVER_IP>:<port>`:

```zsh
# Prometheus UI — reachable at http://<SERVER_IP>:9090
alias pf-prom="docker run --rm -it --network host \
  -v \${POC_DIR}/kube:/root/.kube \
  -e KUBECONFIG=/root/.kube/config \
  --name pf-prom \
  \${TOOLKIT_IMAGE} \
  kubectl port-forward svc/kps-prometheus -n observability 9090:9090"

# Alertmanager UI — reachable at http://<SERVER_IP>:9093
alias pf-alertmanager="docker run --rm -it --network host \
  -v \${POC_DIR}/kube:/root/.kube \
  -e KUBECONFIG=/root/.kube/config \
  --name pf-alertmanager \
  \${TOOLKIT_IMAGE} \
  kubectl port-forward svc/kps-alertmanager -n observability 9093:9093"
```

**Also update** the `poc-stop` function to clean up these new port-forwards
if they were started as background daemons:

```zsh
# In poc-stop(), add:
docker stop pf-prom         2>/dev/null && echo "Prometheus port-forward stopped"   || true
docker stop pf-alertmanager 2>/dev/null && echo "Alertmanager port-forward stopped" || true
```

And update `poc-start`'s closing summary — remove the line referencing
`pf-es` and the `kibana.test` URL.

`source ~/.zshrc` in all open terminals after editing.

### 22 — Fill in version placeholders in CONTEXT.md

```bash
helm list -n observability -o json \
  | jq -r '.[] | "\(.name) \(.app_version // .chart)"'
```

Update the Versions table in CONTEXT.md with actual values for:
- kube-prometheus-stack
- Prometheus (from the `kps-*-prometheus` pod image tag)
- Grafana
- Loki
- Tempo

Then remove the `> **Status:** Reflects intended state...` banner at the top
of CONTEXT.md — it is now reality.

### 23 — Commit

```bash
cd ${POC_DIR}

# First: the planning artifacts (if not committed earlier)
git add decisions/ADR-0001-replace-eck-jaeger-with-lgtm.md
git add documentation/phase-7-lgtm-migration-runbook.md

# Then: the executed state
git add manifests/kube-prometheus-stack-values.yaml
git add manifests/loki-values.yaml
git add manifests/tempo-values.yaml
git add manifests/grafana-datasources.yaml
git add manifests/grafana-ingress.yaml
git add manifests/grafana-dashboard-sensor-demo.yaml
git add manifests/otel-collector-gateway.yaml
git add manifests/otel-collector-gateway-service.yaml
git add manifests/otel-collector-gateway-config.yaml
git add manifests/otel-collector-gateway-podmonitor.yaml

git add documentation/archive/phase7-predecommission/

# Remove retired files
git rm scripts/obs-init.sh 2>/dev/null || true
git rm scripts/obs-ilm-init.sh 2>/dev/null || true

# Finally: CONTEXT.md
git add CONTEXT.md

git commit -m "phase 7: replace ECK/Kibana/Jaeger with LGTM stack

- Remove ECK operator, Elasticsearch, Kibana
- Remove Jaeger (if present on this host)
- Add kube-prometheus-stack (Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics)
- Add Loki (single-binary, filesystem)
- Add Tempo (monolithic, filesystem, metrics-generator enabled)
- Rewrite OTel gateway: new ConfigMap with otlp/tempo + otlphttp/loki + prometheusremotewrite exporters
- Add 8888 metrics port to gateway Deployment and Service
- PodMonitor on gateway for self-telemetry
- Remove ES_PASSWORD env var dependency
- Expose Grafana at https://grafana.test
- Rebuild Phase 5a dashboard in Grafana (provisioned ConfigMap)

See decisions/ADR-0001 for rationale.
See documentation/phase-7-lgtm-migration-runbook.md for build steps."

git push
```

---

## Troubleshooting

### Gateway pod crashloops after Step 12

Most likely: YAML indentation in the ConfigMap, or an exporter endpoint that
can't resolve. Revert to the interim config from Step 1:

```bash
kubectl apply -f /work/otel-collector-gateway-config-phase7-interim.yaml
kubectl rollout restart deployment otel-collector-gateway -n observability
```

Then diff and fix before re-applying the Phase 7 config.

### Loki ingest returning 400 or 500

OTLP endpoint path matters. Loki 3.x accepts OTLP at `/otlp/v1/logs` but the
collector's `otlphttp` exporter appends `/v1/logs` automatically — so the
exporter's `endpoint` field should be `http://loki.../otlp` (without `/v1/logs`).
Double-check the exporter config.

### Tempo metrics-generator produces no metrics

Several distinct failure modes produce this symptom:

**1. Processors not enabled.** The most common cause. `metricsGenerator.enabled: true`
installs the component, but without processors in `tempo.overrides`, the
generator runs idle. See Step 9 — the `tempo.overrides` block with
`service-graphs` and `span-metrics` listed under
`defaults.metrics_generator.processors` is required.

Verify processors are configured:
```bash
kubectl get cm -n observability -l app.kubernetes.io/name=tempo -o yaml \
  | grep -A 5 "metrics_generator_processors\|overrides"
```
You should see `service-graphs` and `span-metrics` listed under
`defaults.metrics_generator.processors` (or in the per-tenant overrides
block if you've moved to multi-tenant).

**2. Warmup period.** Metrics-generator only produces metrics for spans
observed *after* it started. Allow 5+ minutes of span traffic after Tempo
starts before checking.

**3. Wrong remoteWriteUrl.** Check `tempo-values.yaml`'s `remoteWriteUrl`
points at the correct Prometheus service (from Step 7).

**4. Do not grep Tempo logs.** Tempo 2.9 does not log at INFO level when the
generator is healthy. Silence is NOT a diagnostic signal. The reliable
verification is asking Prometheus directly what metric names exist:

```bash
kubectl port-forward -n observability svc/kps-prometheus 9090:9090 &
sleep 2

curl -s 'http://localhost:9090/api/v1/label/__name__/values' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('\n'.join([m for m in d['data'] if 'spanmetric' in m.lower() or 'servicegraph' in m.lower()]))"

kill %1 2>/dev/null
```

Expected output includes `traces_spanmetrics_*` and `traces_service_graph_*`
metric names. If the list is empty after 5+ minutes of span traffic, the
generator is not running correctly — return to cause #1.

### Prometheus shows no metrics from OTel gateway remote-write

Confirm `enableRemoteWriteReceiver` made it to the Prometheus CR:
```bash
kubectl get prometheus -n observability -o yaml | grep -i remoteWriteReceiver
```
If missing, update the helm values, `helm upgrade` kps.

### "No targets" for otel-collector-gateway in Prometheus

The PodMonitor selects on `app=otel-collector-gateway`. Verify the pod label:
```bash
kubectl get pod -n observability -l app=otel-collector-gateway --show-labels
```

### Derived field appears in Fields list but shows 0% / no "View trace" link

The `TraceID` derived field defined in Step 10 appears in Grafana's Fields
panel but shows **0%** — meaning the matcher is registering but not
extracting values from any log line.

This is almost always a field-name problem in the `derivedFields` YAML. The
Loki datasource's provisioning schema overloads `matcherRegex`:

- When `matcherType: regex` (default) — `matcherRegex` is a regex applied
  to the log body.
- When `matcherType: label` — `matcherRegex` is reinterpreted as the
  *label name* (not a regex).

Some older examples use `type: label` and `label: <n>` fields — these
are silently ignored in current Grafana versions, and the field falls back
to regex mode against the log body, producing 0% matches.

**Correct form:**

```yaml
derivedFields:
  - name: TraceID
    matcherType: label
    matcherRegex: trace_id     # label name, not a regex
    url: '$${__value.raw}'
    datasourceUid: tempo
    urlDisplayLabel: View trace
```

### LogQL "No data" when you expected matches

If a query against a stream selector returns "No data" but you can see the
field in an expanded log line, the field is probably structured metadata,
not an indexed stream label. Stream selectors (`{...}`) match only indexed
labels.

**Check whether a field is indexed:**

```bash
kubectl run loki-probe --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 -n observability -- \
  curl -s 'http://loki.observability.svc.cluster.local:3100/loki/api/v1/labels'
```

If the field name isn't in the returned list, it's structured metadata.
Move the filter out of the stream selector into a pipe stage:

```logql
# Wrong — stream selector only matches indexed labels
{service_name="sensor-producer", SensorId=~".+"}

# Right — pipe stage filters structured metadata
{service_name="sensor-producer"} | SensorId != ""
```

### Loki `| json` pipeline error: JSONParserErr

The `| json` parser stage fails if the log body isn't valid JSON. The sensor
demo's log bodies are unstructured text (with unrendered `{TraceId}`-style
template placeholders), so `| json` always errors on these logs.

**Solution:** drop `| json`. The fields you might have wanted to parse
(SensorId, Trend, TraceId, etc.) are already available as structured
metadata — filter them with pipe stages directly (see previous entry).

The underlying bug — log templates writing literal `{TraceId}` strings
instead of interpolating the value — should be fixed in the application
code as a follow-up task. The OTel SDK already attaches trace context as
structured metadata on every log record, so the `[trace:{TraceId}]` prefix
in log bodies is redundant and should be removed from the message templates.

### Grafana sidecar doesn't pick up the dashboard ConfigMap

The ConfigMap needs label `grafana_dashboard: "1"` and must be in a namespace
the sidecar watches (we configured `searchNamespace: ALL`). Check sidecar logs:
```bash
kubectl logs -n observability -l app.kubernetes.io/name=grafana -c grafana-sc-dashboard --tail=50
```

---

## Things to think about later (AKS and beyond)

- **Log collection in AKS** — OTel Collector DaemonSet vs Grafana Alloy vs
  Azure Monitor. Decide after DevOps AKS cluster hands-on.
- **Object storage for Loki/Tempo in production** — Azure Blob default;
  RustFS if/when that matures.
- **Multi-tenant Loki** — `auth_enabled: true` with `X-Scope-OrgID` headers.
- **Grafana SSO** — Azure AD via OIDC. PoC uses local admin.
- **Alerting rules** — Alertmanager is installed with defaults only.
- **Liveness/readiness probes on OTel gateway** — currently none configured.
  Adding them is a small, separate hardening pass.
- **ServiceMonitors for Traefik, Vault, Gitea, ArgoCD** — each has a metrics
  endpoint that should eventually feed Prometheus.
- **Mimir** — revisit if single Prometheus retention or HA becomes painful.
