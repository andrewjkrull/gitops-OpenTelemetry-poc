# Phase 6 — Jaeger Distributed Tracing

Add Jaeger all-in-one to the stack for native trace waterfall view alongside
existing Elasticsearch telemetry. This phase is purely additive — the only
existing resource that changes is the OTel gateway ConfigMap.

---

## Purpose

Elasticsearch and Kibana deliver powerful search-based observability, but the
developer story for "find the slow service and fix it" benefits from a dedicated
trace waterfall UI. Jaeger provides exactly that: a purpose-built trace viewer
that shows the full span tree for any trace ID in one click.

The approach is a fan-out: a second exporter is added to the OTel gateway config
so traces flow to both Elasticsearch **and** Jaeger simultaneously. No application
code changes. No pipeline disruption. Everything built in previous phases continues
to work unchanged.

**What you get after this phase:**

- Jaeger UI at `https://jaeger.test` — full trace waterfall for any trace ID
- Trace fan-out: spans flow to Elasticsearch AND Jaeger in parallel
- Native service dependency graph in Jaeger UI
- End-to-end trace for `sensor-producer → mqtt-bridge → event-consumer` in one waterfall view

**What does not change:**

- Kibana dashboards — all panels continue to work
- Application deployments — no restarts required
- Vault, cert-manager, ArgoCD, Gitea — untouched
- Elasticsearch data streams — no schema changes

---

## Architecture

**Before Phase 6:**

```
sensor-producer ──┐
mqtt-bridge       ├──► OTel DaemonSet ──► OTel Gateway ──► Elasticsearch
event-consumer ───┘
traefik ──────────────────────────────────► OTel Gateway ──► Elasticsearch
```

**After Phase 6:**

```
sensor-producer ──┐
mqtt-bridge       ├──► OTel DaemonSet ──► OTel Gateway ──┬──► Elasticsearch
event-consumer ───┘                                       └──► Jaeger (OTLP gRPC 4317)
traefik ──────────────────────────────────► OTel Gateway ──┬──► Elasticsearch
                                                            └──► Jaeger (OTLP gRPC 4317)
```

Jaeger all-in-one runs in the `observability` namespace. It receives traces via
OTLP/gRPC from the OTel gateway over in-cluster networking — no TLS needed.
It stores everything in memory, which is appropriate for a PoC demo context.
The Jaeger UI is exposed through Traefik via IngressRoute, same pattern as every
other `.test` service.

> **In-memory storage:** Trace data is lost on pod restart. This is intentional.
> For persistent storage, Jaeger supports Cassandra, Elasticsearch, and Badger
> backends — out of scope here.

**Component versions:**

| Component | Version |
|-----------|---------|
| Jaeger all-in-one | `jaegertracing/all-in-one:2.17.0` |
| Jaeger Helm chart | `jaegertracing/jaeger` 4.7.0 |
| OTLP gRPC port | 4317 (standard — already open on OTel gateway pod) |

---

## Pre-flight checks

Run all of these before making any changes.

**PF-1 — OTel gateway is healthy:**

```bash
kubectl get pods -n observability -l app=otel-collector-gateway
# Expected: 1/1 Running

kubectl get pods -n observability -l app=otel-collector-daemonset
# Expected: 3/3 Running (one per node)
```

**PF-2 — Elasticsearch is receiving traces:**

```bash
ES_PASS=$(kubectl get secret elasticsearch-es-elastic-user \
  -n observability -o jsonpath='{.data.elastic}' | base64 -d | tr -d '\r\n')

curl -sk -u "elastic:${ES_PASS}" \
  "https://localhost:9200/traces-generic.otel-default/_count" | jq .count
# Expected: count > 0
```

> `pf-es` must be running for this check.

**PF-3 — Sensor apps are running:**

```bash
kubectl get pods -n sensor-dev
# Expected: sensor-producer, mqtt-bridge, event-consumer all 2/2 Running
```

**PF-4 — Traefik is healthy:**

```bash
kubectl get pods -n traefik
# Expected: 1/1 Running

curl -sk https://whoami.test | grep -i hostname
# Expected: Hostname: <pod-name>
```

**PF-5 — Check for existing jaeger.test DNS entry:**

```bash
grep jaeger /etc/hosts
# If no output — add the entry in Step 1
```

---

## Implementation

> **Read each step in full before running commands.** The step that modifies an
> existing resource is clearly marked. All other steps create new resources only.

---

### Step 1 — Add `jaeger.test` to `/etc/hosts`

Same pattern as all other `.test` domains.

**On the Linux host:**

```bash
grep jaeger /etc/hosts

# If not present:
echo '127.0.0.1  jaeger.test' | sudo tee -a /etc/hosts
```

**On your Windows workstation (PowerShell as Administrator)** — replace
`<SERVER_IP>` with the server's actual IP:

```powershell
Add-Content -Path C:\Windows\System32\drivers\etc\hosts `
  -Value '<SERVER_IP>  jaeger.test'
```

---

### Step 2 — Add the Jaeger Helm repository

Read-only — nothing in the cluster changes.

```bash
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
helm repo update
helm search repo jaegertracing/jaeger --versions | head -5
```

---

### Step 3 — Create Jaeger Helm values file

New file. Nothing existing is modified.

**File:** `${POC_DIR}/manifests/jaeger-values.yaml`

```bash
cat > ${POC_DIR}/manifests/jaeger-values.yaml << 'YAML'
# Phase 6 — Jaeger all-in-one
# In-memory storage: data is lost on pod restart (PoC only)

provisionDataStore:
  cassandra: false
  elasticsearch: false
  kafka: false

allInOne:
  enabled: true
  image:
    registry: docker.io
    repository: jaegertracing/all-in-one
    tag: "2.17.0"
  extraEnv:
    - name: COLLECTOR_OTLP_ENABLED
      value: "true"
    - name: SPAN_STORAGE_TYPE
      value: memory
    - name: MEMORY_MAX_TRACES
      value: "50000"
  resources:
    limits:
      memory: 512Mi
    requests:
      memory: 256Mi
      cpu: 100m

# Disable components not needed for all-in-one mode
collector:
  enabled: false
query:
  enabled: false
agent:
  enabled: false

# Ports used:
#   16686 — Jaeger UI / query HTTP
#   4317  — OTLP gRPC receiver (OTel collector fan-out)
#   4318  — OTLP HTTP receiver
YAML
```

> `MEMORY_MAX_TRACES: 50000` — at roughly 4 spans per trace for this stack, that
> is ~12,500 end-to-end traces. At 1-second sensor intervals that is over 3 hours
> of trace history before eviction.

---

### Step 4 — Install Jaeger via Helm

New resources in the `observability` namespace. Nothing existing is touched.

```bash
helm install jaeger jaegertracing/jaeger \
  --namespace observability \
  --values /work/jaeger-values.yaml \
  --wait --timeout 3m

# Verify
kubectl get pods -n observability -l app.kubernetes.io/name=jaeger
# Expected: jaeger-XXXXX   1/1   Running
```

Verify the OTLP gRPC port is reachable from within the cluster:

```bash
kubectl run tmp-shell --rm -it --restart=Never \
  --image=busybox -n observability \
  -- sh -c 'nc -zv jaeger.observability.svc.cluster.local 4317'
# Expected: jaeger.observability.svc.cluster.local (x.x.x.x:4317) open
```

> A `1/1 Running` pod is sufficient confirmation to proceed — `ss` is not
> available in the Jaeger container image.
>
> Note: in all-in-one mode the Helm chart creates a single service named `jaeger`
> (not `jaeger-collector` or `jaeger-query`). All ports — OTLP, UI, query — are
> on this one service.

---

### Step 5 — Create TLS certificate and IngressRoute

Two new files. Same cert-manager and IngressRoute pattern as every other service.

**File:** `${POC_DIR}/manifests/jaeger-cert.yaml`

```bash
cat > ${POC_DIR}/manifests/jaeger-cert.yaml << 'YAML'
# Phase 6 — cert-manager Certificate for jaeger.test
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: jaeger-tls
  namespace: observability
spec:
  secretName: jaeger-tls
  issuerRef:
    name: vault-issuer
    kind: ClusterIssuer
  commonName: jaeger.test
  dnsNames:
    - jaeger.test
YAML
```

**File:** `${POC_DIR}/manifests/jaeger-ingressroute.yaml`

```bash
cat > ${POC_DIR}/manifests/jaeger-ingressroute.yaml << 'YAML'
# Phase 6 — Jaeger UI IngressRoute
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: jaeger
  namespace: observability
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`jaeger.test`)
      kind: Rule
      services:
        - name: jaeger
          port: 16686
  tls:
    secretName: jaeger-tls
YAML
```

Apply both:

```bash
kubectl apply -f /work/jaeger-cert.yaml
kubectl apply -f /work/jaeger-ingressroute.yaml

# Wait for cert to be issued
kubectl get certificate -n observability jaeger-tls -w
# Expected: READY   True
```

> The `vault-issuer` ClusterIssuer was created in Phase 1 and signs any
> `*.test` certificate. No Vault changes needed.

---

### Step 6 — Update OTel gateway ConfigMap (fan-out)

> ⚠️ **This is the only step that modifies an existing resource.**
>
> The existing `manifests/otel-gateway-config.yaml` is **not touched**. A new
> separate file `otel-gateway-config-phase6.yaml` is written and applied instead.
> This preserves the working base config as a clean rollback target — to undo
> Phase 6 you simply reapply the original file.

The OTel gateway ConfigMap gets a second exporter added to the traces pipeline.
The Elasticsearch exporter and all other pipelines are left completely unchanged.

**What changes in the ConfigMap:**
- `exporters:` block — add `otlp/jaeger` exporter entry
- `service.pipelines.traces.exporters:` — append `otlp/jaeger` to the existing list

**What does not change:**
- The `elasticsearch` exporter block
- The `metrics` and `logs` pipelines
- Receivers and processors

**Important:** do not apply this file until Jaeger is confirmed running (Step 4
complete, pod `1/1 Running`). The OTel collector validates all configured exporters
at startup — if `jaeger.observability.svc.cluster.local:4317` is not reachable the
gateway pod will fail to start and take down the entire trace pipeline.

**First — confirm the live ConfigMap matches the base file before touching anything:**

```bash
kubectl get configmap otel-collector-gateway-config -n observability -o yaml
# Confirm this matches manifests/otel-gateway-config.yaml before proceeding
```

**Create the Phase 6 config file** — new file, base config is untouched:

**File:** `${POC_DIR}/manifests/otel-gateway-config-phase6.yaml`

```bash
cat > ${POC_DIR}/manifests/otel-gateway-config-phase6.yaml << 'YAML'
# Phase 6 OTel gateway config — adds Jaeger fan-out to the traces pipeline.
# DO NOT apply this until Jaeger is confirmed running (Step 4 complete).
# To roll back: kubectl apply -f /work/otel-gateway-config.yaml
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
      # --- existing (unchanged) ---
      elasticsearch:
        endpoints:
          - https://elasticsearch-es-http.observability.svc.cluster.local:9200
        user: elastic
        password: ${env:ES_PASSWORD}
        tls:
          insecure_skip_verify: true
        flush:
          interval: 5s
          bytes: 5242880
        retry:
          enabled: true
          max_requests: 3
      # --- new (Phase 6) ---
      otlp/jaeger:
        endpoint: jaeger.observability.svc.cluster.local:4317
        tls:
          insecure: true

    service:
      telemetry:
        logs:
          level: warn
      pipelines:
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [elasticsearch]
        logs:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [elasticsearch]
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [elasticsearch, otlp/jaeger]   # <-- Phase 6: fan-out added
YAML
```

Apply and restart:

```bash
kubectl apply -f /work/otel-gateway-config-phase6.yaml
```

Check whether the gateway deployment carries the Reloader annotation:

```bash
kubectl get deployment -n observability otel-collector-gateway \
  -o jsonpath='{.metadata.annotations}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('reloader.stakater.com/auto','not set'))"
# Expected if Reloader is active: true
# Expected if not configured:     not set
```

If `reloader.stakater.com/auto: "true"` is present, Reloader will restart the
pod automatically within 30 seconds — skip the manual rollout below.

If the annotation is **not** present:

```bash
kubectl annotate deployment otel-collector-gateway -n observability \
  reloader.stakater.com/auto=true --overwrite

kubectl rollout restart deployment/otel-collector-gateway -n observability
kubectl rollout status deployment/otel-collector-gateway -n observability
# Expected: successfully rolled out
```

Verify the gateway started cleanly with both exporters active:

```bash
kubectl logs -n observability -l app=otel-collector-gateway --tail=50 \
  | grep -E 'exporter|error|warn'
# Expected: exporter started for both elasticsearch and otlp/jaeger
# No error lines
```

> ⚠️ **If the gateway pod enters CrashLoopBackOff** — roll back immediately:
> ```bash
> kubectl rollout undo deployment/otel-collector-gateway -n observability
> ```
> Then check the logs for a YAML indentation error. The `config.yaml` content
> inside the ConfigMap `data` block must be indented by exactly 4 spaces.

---

### Step 7 — Verify Jaeger is receiving traces

Wait 60 seconds after the gateway restart, then check.

**API check:**

```bash
curl -s 'https://jaeger.test/api/services' | jq '.data[]'
# Expected: "sensor-producer", "mqtt-bridge", "event-consumer", "traefik"
```

If the services list is empty, wait another 60 seconds — the sensor apps generate
one trace per second so Jaeger will populate quickly once the gateway is forwarding.

**Browser check:**

```
https://jaeger.test
  → Service: sensor-producer
  → Find Traces
  → Expected: list of recent traces, each showing 4 spans
```

---

### Step 8 — Add toolkit aliases

Quality-of-life only. Nothing in the cluster is affected.

Add to `${POC_DIR}/documentation/poc-toolkit.zsh` after the existing Kibana aliases:

```zsh
# Phase 6 — Jaeger
alias pf-jaeger='kubectl port-forward svc/jaeger -n observability 16686:16686'
```

Reload:

```bash
source ~/.zshrc
```

> `pf-jaeger` is for debugging only. Normal access to the Jaeger UI is through
> Traefik at `https://jaeger.test` without any port-forward.

---

## Verification

Run this sequence after all steps are complete.

**V1 — Infrastructure health:**

```bash
kubectl get pods -n observability
# Must all be Running:
#   elasticsearch-es-*             1/1
#   kibana-kb-*                    1/1
#   otel-collector-gateway-*       1/1
#   otel-collector-daemonset-*     1/1  (3 pods)
#   jaeger-*                       1/1  (new)

kubectl get certificate -n observability jaeger-tls
# READY: True

kubectl get ingressroute -n observability jaeger
# Expected: resource exists
```

**V2 — Trace fan-out confirmation:**

```bash
kubectl logs -n observability -l app=otel-collector-gateway --tail=100 \
  | grep -E '(elasticsearch|otlp/jaeger).*sent'

# Confirm ES trace count is still climbing
ES_PASS=$(kubectl get secret elasticsearch-es-elastic-user \
  -n observability -o jsonpath='{.data.elastic}' | base64 -d | tr -d '\r\n')
curl -sk -u "elastic:${ES_PASS}" \
  'https://localhost:9200/traces-generic.otel-default/_count' | jq .count
```

**V3 — Jaeger UI end-to-end:**

1. Open `https://jaeger.test`
2. Select Service: `sensor-producer` → Find Traces
3. Click any trace — verify the waterfall shows all 4 expected spans:
   - `sensor-producer` root span
   - `mqtt-bridge` child span (MQTT receive)
   - `mqtt-bridge` child span (Kafka publish)
   - `event-consumer` child span (Kafka receive)
4. Open the **System Architecture** tab — all four services should appear with edges

**V4 — Kibana still working:**

```
https://kibana.test → Dashboard → Sensor Demo — Observability Overview
All 7 panels showing live data. No "No results" panels.
```

---

## Demo script addition

Add this beat after the Phase 5b latency injection beat.

**Setup:** Jaeger UI open in a tab alongside the Kibana dashboard.

**Beat 1 — Inject latency (existing Phase 5b):**
Push `BRIDGE_DELAY_MS` change via GitOps. Show the Service Latency panel in
Kibana spike on `mqtt-bridge`.

**Beat 2 — Pivot to Jaeger:**
- Switch to the Jaeger tab
- Service: `mqtt-bridge` → Find Traces
- "Notice these traces are taking 500+ ms — let's look at one"
- Click a trace — the waterfall opens
- Point to the `mqtt-bridge` span: "You can see exactly where the 500ms sits —
  right here in the bridge service, before the Kafka publish"
- Point to `sensor-producer` and `event-consumer`: "The producer and consumer
  are healthy — the problem is isolated to one service"

**Beat 3 — Fix and verify:**
- Return to GitOps, set `BRIDGE_DELAY_MS` back to `0`
- Back in Jaeger: Find Traces again — new traces show sub-millisecond `mqtt-bridge` spans
- "Same tool, same trace ID structure, zero config change to the apps"

**Key talking points:**
- "Jaeger and Kibana are reading the same trace data — the OTel collector fans out to both simultaneously"
- "No changes to application code. The tracing infrastructure was already in place from Phase 2"
- "In production you would keep both: Kibana for aggregated dashboards and alerting, Jaeger for developer trace investigation"

---

## Troubleshooting

**Jaeger pod not starting:**

```bash
kubectl describe pod -n observability -l app.kubernetes.io/name=jaeger
kubectl logs -n observability -l app.kubernetes.io/name=jaeger --previous
```

- `OOMKilled` → increase `memory.limits` in `jaeger-values.yaml`, then `helm upgrade`
- `ImagePullBackOff` → check internet access from k3d nodes, verify image tag exists

---

**Jaeger UI shows no services after setup:**

```bash
# 1. Is the gateway actually sending to Jaeger?
kubectl logs -n observability -l app=otel-collector-gateway --tail=100 | grep -i 'otlp/jaeger'

# 2. Does the Jaeger collector service have endpoints?
kubectl get svc -n observability | grep jaeger
kubectl get endpoints -n observability jaeger

# 3. Can the gateway pod reach Jaeger?
GW_POD=$(kubectl get pod -n observability -l app=otel-collector-gateway \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n observability ${GW_POD} -- \
  /bin/sh -c 'nc -zv jaeger.observability.svc.cluster.local 4317'
# Expected: succeeded
```

---

**OTel gateway crashloops after ConfigMap update:**

```bash
# Immediate rollback
kubectl rollout undo deployment/otel-collector-gateway -n observability
kubectl rollout status deployment/otel-collector-gateway -n observability

# Read the error
kubectl logs -n observability -l app=otel-collector-gateway --previous | tail -30
```

Most common cause: YAML indentation error inside the ConfigMap `data` block.
The `config.yaml` content must be indented 4 spaces under the `data:` key.

---

**`https://jaeger.test` returns 404:**

```bash
kubectl get ingressroute -n observability jaeger
kubectl get certificate -n observability jaeger-tls
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=30 | grep jaeger
kubectl get svc -n observability jaeger
```

---

**Jaeger has traces but ES has gaps:**

The two exporters are independent — a failure in one does not affect the other.
Check the gateway logs for Elasticsearch-specific export errors:

```bash
kubectl logs -n observability -l app=otel-collector-gateway --tail=200 \
  | grep -E '(elasticsearch|error|fail)' | tail -20
```

---

## Rollback

**Roll back the OTel gateway config:**

```bash
# Reapply the original base config — removes the Jaeger exporter entirely
kubectl apply -f /work/otel-gateway-config.yaml
kubectl rollout restart deployment/otel-collector-gateway -n observability
kubectl rollout status deployment/otel-collector-gateway -n observability
```

> `otel-gateway-config.yaml` (the base file) was never modified during Phase 6
> so it is always a clean rollback target.

**Remove Jaeger entirely:**

```bash
helm uninstall jaeger -n observability
kubectl delete ingressroute jaeger -n observability
kubectl delete certificate jaeger-tls -n observability
kubectl delete secret jaeger-tls -n observability
```

**Clean up DNS:**

```bash
sudo sed -i '/jaeger.test/d' /etc/hosts
# Also remove from Windows hosts file if added
```

> After rolling back the gateway config, Elasticsearch and Kibana continue working
> exactly as before Phase 6. No trace data is lost from Elasticsearch.

---

## CONTEXT.md updates

After completing this phase, update `CONTEXT.md`:

**Version table — add:**

| Component | Version |
|-----------|---------|
| Jaeger all-in-one | 2.17.0 |
| Jaeger Helm chart | jaegertracing/jaeger 4.7.0 |

**What is built and working — add after Phase 5a:**

```
### Phase 6 — Jaeger Distributed Tracing ✅

- Jaeger all-in-one 2.17.0 in observability namespace, in-memory storage
- OTel gateway fan-out: traces → Elasticsearch AND Jaeger simultaneously
- Jaeger UI at https://jaeger.test — full trace waterfall, service dependency graph
- 4-span trace (sensor-producer → mqtt-bridge → event-consumer) visible end-to-end
- cert-manager TLS certificate for jaeger.test (Vault CA, same pattern as all other .test certs)
- Traefik IngressRoute pattern identical to all other observability services
```

**Accessing services table — add:**

| Service | URL | Notes |
|---------|-----|-------|
| Jaeger UI | https://jaeger.test | No login — anonymous access |
