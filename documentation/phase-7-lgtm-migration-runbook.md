# Phase 7 — LGTM Migration Runbook

Replace ECK (Elasticsearch + Kibana) with the Grafana **LGTM** stack:
**L**oki (logs), **G**rafana (UI), **T**empo (traces), and Prometheus (metrics —
we use plain Prometheus at PoC scale, not Mimir).

This runbook is **verified against the actual cluster state** on `Cyclone` as of
2026-04-19. Every resource name, port, ConfigMap key, and Service reference has
been checked. Do not substitute or abstract — apply as written.

> **Note on Jaeger — varies by host.** Jaeger was installed on the work
> `devajk01` host during Phase 6 but was never replicated to the home
> `Cyclone` host. Step 2 (Jaeger teardown) is conditional: run it on hosts
> where Jaeger exists, skip it where it does not. Check with:
> ```bash
> kubectl get ns tracing 2>/dev/null && helm list -n tracing 2>/dev/null
> ```
> If both return nothing, skip Step 2 and move to Step 3.

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
| Prometheus | not exposed via Traefik — port-forward for debugging | — |
| Loki | not exposed — accessed only via Grafana | — |
| Tempo | not exposed — accessed only via Grafana | — |

Only Grafana is ingressed. Loki, Tempo, and Prometheus stay cluster-internal.

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

### 2a — Uninstall Jaeger (conditional — skip if no `tracing` namespace)

Run this step only on hosts where Jaeger was deployed during Phase 6. As noted
at the top: `Cyclone` (home) has no Jaeger — skip this step. `devajk01` (work)
has Jaeger — run it.

Check first:

```bash
kubectl get ns tracing 2>/dev/null && helm list -n tracing 2>/dev/null
# If this returns nothing: skip to Step 2b
```

If Jaeger is present:

```bash
# Uninstall the Helm release — adjust release name if yours differs
helm list -n tracing
# Typical release name: jaeger
helm uninstall jaeger -n tracing

# Remove any Jaeger-specific IngressRoute
kubectl get ingressroute -n tracing
kubectl delete ingressroute jaeger -n tracing 2>/dev/null || true

# Remove any Jaeger PVCs (all-in-one uses in-memory storage by default, but
# some Helm chart configurations use a badger PVC — remove to be safe)
kubectl delete pvc -n tracing --all 2>/dev/null || true

# Remove the namespace
kubectl delete namespace tracing

# Verify
kubectl get ns | grep tracing
# Expect: no output
helm list -A | grep -i jaeger
# Expect: no output
```

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

# Any IngressRoutes referencing Kibana
kubectl get ingressroute -n observability
kubectl delete ingressroute kibana -n observability 2>/dev/null || true
# If there's a Kibana IngressRoute by a different name, delete by observed name
```

### 3 — Uninstall the ECK operator

```bash
helm uninstall elastic-operator -n elastic-system
kubectl delete namespace elastic-system

# Remove the CRDs so a future re-install isn't polluted
kubectl get crd -o name | grep elastic.co | xargs -r kubectl delete
```

### 4 — Clean up ES credentials from the cluster and Vault

```bash
# Kubernetes secrets
kubectl delete secret otel-es-credentials -n observability 2>/dev/null || true
kubectl delete secret elasticsearch-es-elastic-user -n observability 2>/dev/null || true

# Vault path (optional — can leave it, the ADR rationale notes this)
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

```bash
GRAFANA_PASS=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)

vault kv put secret/observability/grafana \
  username=admin \
  password="${GRAFANA_PASS}"

# Write to /tmp/poc and apply separately — the kubectl alias runs each
# invocation in a separate container, so piping two kubectl calls together
# causes a container name conflict (see CONTEXT.md critical gotchas).
kubectl create secret generic grafana-admin \
  --namespace observability \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="${GRAFANA_PASS}" \
  --dry-run=client -o yaml > /tmp/poc/grafana-admin-secret.yaml

kubectl apply -f /tmp/poc/grafana-admin-secret.yaml
rm /tmp/poc/grafana-admin-secret.yaml
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
    retention: 2h
    retentionSize: 1GiB
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
  --namespace observability \
  --values /work/kube-prometheus-stack-values.yaml \
  --wait --timeout 10m

kubectl get pods -n observability -l release=kps
```

Wait for all pods Running. Then verify the actual service names the chart
produced (the runbook's next steps reference these — if the names differ in a
future chart version, the datasource and OTel exporter configs must match
whatever is actually in the cluster):

```bash
kubectl get svc -n observability -l release=kps
# Key services to note for later steps:
#   kps-grafana
#   kps-kube-prometheus-stack-prometheus (or similar — the "prometheus" port 9090 one)
#   kps-kube-prometheus-stack-alertmanager
```

**⚠ Save the exact Prometheus service name for Step 10 and Step 12.** It's
typically `kps-kube-prometheus-stack-prometheus`. Confirm with:

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
    retention_period: 24h
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

tempo:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
  storage:
    trace:
      backend: local
      local:
        path: /var/tempo/traces
      wal:
        path: /var/tempo/wal
  retention: 24h
  metricsGenerator:
    enabled: true
    # NOTE: The Prometheus URL here references the service name from Step 7.
    # If your kps Prometheus service is named differently, update this line.
    remoteWriteUrl: "http://kps-kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090/api/v1/write"

persistence:
  enabled: true
  size: 5Gi

resources:
  requests: { cpu: 100m, memory: 256Mi }
  limits:   { cpu: 1,    memory: 1Gi  }

serviceMonitor:
  enabled: true
  labels: { release: kps }
EOF
```

> **⚠ Before applying:** confirm the Prometheus service name matches the
> `remoteWriteUrl` above. Run:
> ```bash
> kubectl get svc -n observability -o name | grep -i prometheus | grep -v operator
> ```
> If the service is not `kps-kube-prometheus-stack-prometheus`, edit the
> `remoteWriteUrl` in `tempo-values.yaml` before installing.

Install:

```bash
helm upgrade --install tempo grafana/tempo \
  --namespace observability \
  --values /work/tempo-values.yaml \
  --wait --timeout 10m

kubectl get pods -n observability -l app.kubernetes.io/name=tempo
kubectl logs -n observability -l app.kubernetes.io/name=tempo --tail=30

# Get the actual Tempo service name
kubectl get svc -n observability -l app.kubernetes.io/name=tempo
```

**⚠ Save the Tempo service name for Step 10 and Step 12.** Typically `tempo`
on port 3100 (query) and 4317 (OTLP gRPC). Confirm both ports exist.

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
            - name: TraceID
              # Matches trace_id / traceId / TraceId variations, JSON or plain
              matcherRegex: '"?[Tt]race[_-]?[Ii]d"?[:=]\s*"?([a-f0-9]{32})"?'
              url: '$${__value.raw}'
              datasourceUid: tempo
              urlDisplayLabel: View trace

      - name: Tempo
        type: tempo
        uid: tempo
        access: proxy
        # Update if your tempo service is named differently
        url: http://tempo.observability.svc.cluster.local:3100
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
EOF
```

Apply:

```bash
kubectl apply -f /work/grafana-datasources.yaml

# Watch Grafana's sidecar pick up the new ConfigMap
kubectl logs -n observability -l app.kubernetes.io/name=grafana -c grafana-sc-datasources --tail=20
# Expect a line mentioning 'grafana-datasources-lgtm'
```

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

In Grafana: **Connections → Data sources**. Three datasources (Prometheus auto-provisioned
by kps, Loki, Tempo). Click each and "Test" — all three must return green.

**Do not proceed past this point if any datasource fails.** Every panel depends
on these working.

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
        endpoint: http://kps-kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090/api/v1/write
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
          address: 0.0.0.0:8888
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

# Verify Prometheus picked it up — port-forward and check targets
kubectl port-forward -n observability svc/kps-kube-prometheus-stack-prometheus 9090:9090 &
# Open http://localhost:9090/targets in a browser
# Find the otel-collector-gateway target — should be UP
# Ctrl-C when done
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
# Port-forward if not already
kubectl port-forward -n observability svc/kps-kube-prometheus-stack-prometheus 9090:9090 &

# Open http://localhost:9090
# Run these queries in the expression browser:
#   up
#   otelcol_exporter_sent_spans_total
#   otelcol_exporter_sent_log_records_total
#   kube_pod_info{namespace="sensor-dev"}
# All should return data.
```

In Grafana: Explore → **Prometheus** → Metrics browser. Hundreds of metrics
should be available.

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

**Before building the dashboard, test every query in Explore first.** Some
depend on data streams that need warmup time (Tempo metrics-generator takes
~5 minutes of span traffic). If a query returns nothing in Explore, the panel
will be empty too.

**Starter queries — verify in Explore, then copy into panels:**

**Panel 1 — Service Latency Over Time (PromQL):**
```promql
histogram_quantile(0.95,
  sum by (service, le) (
    rate(traces_spanmetrics_latency_bucket[5m])
  )
)
```

**Panel 2 — Event Throughput by Sensor (LogQL):**
```logql
sum by (SensorId) (
  count_over_time({service_name="sensor-producer"} | json | SensorId != "" [1m])
)
```

**Panel 3 — Sensor Trend Distribution (LogQL, pie chart):**
```logql
sum by (Trend) (
  count_over_time({service_name="mqtt-bridge"} | json | Trend != "" [5m])
)
```

**Panel 4 — Error Span Rate (PromQL):**
```promql
sum by (service) (
  rate(traces_spanmetrics_calls_total{status_code="STATUS_CODE_ERROR"}[5m])
)
```

**Panel 5 — Trace Span Timeline:** Tempo panel, query type "TraceQL".
Add a dashboard text variable `$trace_id`. Query: `${trace_id}`.

**Panel 6 — Event Consumer Logs (LogQL, Logs panel):**
```logql
{service_name="event-consumer"}
```

**Panel 7 — Cross-Service Log Correlation (LogQL, Logs panel):**
```logql
{service_name=~"sensor-producer|mqtt-bridge|event-consumer"} | json
```

Build-and-commit workflow:
1. Create the dashboard interactively in Grafana UI, panel by panel.
2. Name it `Sensor Demo — Observability Overview`, time range Last 1 hour, refresh 30s.
3. Dashboard settings → JSON Model → Copy.
4. Save to `manifests/grafana-dashboard-sensor-demo.yaml` wrapped in a ConfigMap:

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
    <paste exported JSON here>
```

5. Apply: `kubectl apply -f /work/grafana-dashboard-sensor-demo.yaml`
6. Grafana sidecar hot-reloads. Dashboard persists across cluster restarts.

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

### 20 — Update workstation hosts files

- Windows workstation `C:\Windows\System32\drivers\etc\hosts`: remove `kibana.test`,
  add `grafana.test` (same server IP)
- Linux host `/etc/hosts`: same swap
- k3d node `/etc/hosts` via `coredns-patch.sh` — no change needed; CoreDNS
  rewrite handles `*.test` cluster-internally

### 21 — Update toolkit zsh helpers

Edit `~/.zshrc.d/poc-toolkit.zsh`:

- Remove `pf-es` (no Elasticsearch to port-forward)
- Remove `es-pass` function (no ES credentials)
- Add `grafana-pass` function:
  ```zsh
  grafana-pass() {
    kubectl get secret grafana-admin -n observability \
      -o jsonpath='{.data.admin-password}' | base64 -d
    echo
  }
  ```
- Add `pf-prom` for port-forwarding Prometheus:
  ```zsh
  alias pf-prom='kubectl port-forward -n observability svc/kps-kube-prometheus-stack-prometheus 9090:9090'
  ```

`source ~/.zshrc` in all open terminals after.

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

### Tempo metrics-generator panels (Panel 1, Panel 4) stay empty

Metrics-generator only produces metrics for spans observed *after* it started.
Allow 5+ minutes of span traffic. If still empty after 10 minutes:

```bash
kubectl logs -n observability -l app.kubernetes.io/name=tempo | grep -i metrics-gen
```

Common cause: `remoteWriteUrl` in `tempo-values.yaml` pointing at the wrong
Prometheus service.

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
