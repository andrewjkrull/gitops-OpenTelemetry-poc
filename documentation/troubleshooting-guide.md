# Kubernetes PoC — Troubleshooting Guide

A reference for diagnosing problems in the k3d + Vault + Traefik + Elasticsearch + OTel stack.
Covers what each command does, why you run it, and how to interpret the output.

---

## How to think about this stack

Before running any command, it helps to know where in the pipeline a problem lives.
Data flows in one direction:

```
Application/Traefik
       │ OTLP gRPC
       ▼
OTel DaemonSet (per node)
       │ OTLP gRPC
       ▼
OTel Gateway (Deployment)
       │ HTTPS bulk API
       ▼
Elasticsearch
       │
       ▼
Kibana (reads via REST API)
```

TLS certificates flow differently:

```
cert-manager
    │ authenticates via k8s ServiceAccount token
    ▼
Vault PKI (pki_int/sign/cert-manager)
    │ issues signed cert
    ▼
cert-manager stores in k8s Secret
    │
    ▼
Traefik reads Secret, terminates TLS
```

When something is broken, ask: **which hop in the chain is failing?**
The commands in this guide are organized by hop.

---

## Part 1 — Cluster health

### Are nodes ready?

```bash
kubectl get nodes
```

**What this does:** Lists all nodes in the cluster with their status.
**What to look for:** All three nodes (`k3d-poc-server-0`, `k3d-poc-agent-0`, `k3d-poc-agent-1`) should show `Ready`.
**If not Ready:** The cluster may still be starting. Run `kubectl get nodes -w` to watch and wait.

```bash
kubectl get nodes -w
# -w = watch, updates in real time. Ctrl+C to stop.
```

### Are system pods healthy?

```bash
kubectl get pods -A | grep -v Running | grep -v Completed
```

**What this does:** Lists all pods across all namespaces, filtering out healthy ones.
**What to look for:** Any pods in `CrashLoopBackOff`, `Error`, `Pending`, or `ImagePullBackOff`.
**Why:** A failing system pod (e.g., coredns) can cause cascading failures in other components.

### Check events for recent errors

```bash
kubectl get events -A --sort-by='.lastTimestamp' | tail -20
```

**What this does:** Shows the 20 most recent events cluster-wide, sorted by time.
**What to look for:** `Warning` events, especially `Failed`, `BackOff`, `Unhealthy`.
**Why:** Events often explain *why* a pod failed before the pod's own logs are available.

---

## Part 2 — Pod debugging

### Basic pod status

```bash
kubectl get pods -n <namespace>
```

Common status values and what they mean:

| Status | Meaning |
|--------|---------|
| `Running` | Container is running — does NOT mean it's working correctly |
| `Pending` | Waiting to be scheduled — usually resource or image pull issue |
| `CrashLoopBackOff` | Container keeps crashing — check logs immediately |
| `ImagePullBackOff` | Can't pull the container image — check image name/tag |
| `Error` | Container exited with non-zero code |
| `Terminating` | Being deleted — normal during rollouts |
| `0/1 Ready` | Running but readiness probe failing |

### Describe a pod — the most useful debugging command

```bash
kubectl describe pod <pod-name> -n <namespace>
```

**What this does:** Shows everything Kubernetes knows about a pod — scheduling decisions,
container state, resource limits, volume mounts, events, and last termination reason.

**Key sections to look at:**

```
State:          Running / Waiting / Terminated
  Reason:       (if not Running — e.g., CrashLoopBackOff, OOMKilled)
  Exit Code:    (non-zero = problem)
Last State:     (previous container run — useful for crash loops)
Events:         (at the bottom — most useful part)
```

**Example — find why a pod keeps crashing:**

```bash
kubectl describe pod otel-collector-gateway-<hash> -n observability \
  | grep -A5 "State:\|Last State:\|Exit Code:\|Events:"
```

### Read pod logs

```bash
kubectl logs <pod-name> -n <namespace>
```

Useful flags:

```bash
# Show only recent logs
kubectl logs <pod-name> -n <namespace> --since=5m

# Follow logs in real time
kubectl logs <pod-name> -n <namespace> -f

# Show logs from previous container run (before a crash)
kubectl logs <pod-name> -n <namespace> --previous

# For pods with multiple containers, specify which one
kubectl logs <pod-name> -n <namespace> -c <container-name>
```

**For Deployments** (don't need the exact pod name):

```bash
kubectl logs deployment/<name> -n <namespace> --since=2m
```

**For DaemonSets** (logs from all pods, uses first pod by default):

```bash
kubectl logs daemonset/<name> -n <namespace> --since=2m
# Note: "Found 3 pods, using pod/..." is normal
```

### Exec into a pod

Some images have a shell, some don't. The OTel collector image is distroless
(no shell). Use this pattern to check if exec is available:

```bash
kubectl exec <pod-name> -n <namespace> -- sh -c 'echo ok'
# If "exec: sh: not found" → distroless image, can't exec
```

For distroless pods, use `kubectl describe` and logs instead.

---

## Part 3 — Running temporary debug containers

When you need to test network connectivity or inspect the cluster from the inside,
spin up a temporary container. It runs inside the cluster, uses cluster DNS,
and is deleted automatically when done.

### Basic connectivity test with curl

```bash
kubectl run curl-test --rm -it --restart=Never \
  --image=curlimages/curl:latest \
  -n <namespace> -- \
  curl -sk -o /dev/null -w "%{http_code}" https://<service>:<port>
```

**What this does:** Creates a temporary pod, runs curl, prints the HTTP status code, then deletes itself.
- `--rm` = delete pod when done
- `-it` = interactive terminal
- `--restart=Never` = don't restart on exit (makes it a Job, not a Deployment)

**HTTP status codes to know:**

| Code | Meaning |
|------|---------|
| `200` | OK |
| `302` | Redirect (normal for Kibana login page) |
| `401` | Unauthorized — wrong credentials |
| `404` | Not found — wrong path or service not routing |
| `500` | Server error — backend problem |
| `000` | No response — port not reachable, service down, or DNS failure |

### Test a service from a different namespace

Services in Kubernetes are addressable as `<service>.<namespace>.svc.cluster.local`:

```bash
# Test Elasticsearch from the traefik namespace
kubectl run es-test --rm -it --restart=Never \
  --image=curlimages/curl:latest \
  -n traefik -- \
  curl -sk -o /dev/null -w "%{http_code}" \
  https://elasticsearch-es-http.observability.svc.cluster.local:9200
# Expected: 200 or 401 (reachable). 000 = not reachable.
```

**Why this matters:** Traefik proxies to Kibana over HTTPS inside the cluster.
If Traefik can't reach the Kibana service, users get a 500 error.
Testing from inside the traefik namespace confirms whether the network path works.

### Inspect a volume or filesystem path

```bash
kubectl run fs-check --rm -it --restart=Never \
  --image=busybox \
  --overrides='{
    "spec": {
      "volumes": [{"name": "logs", "hostPath": {"path": "/var/log/pods"}}],
      "containers": [{
        "name": "fs-check",
        "image": "busybox",
        "command": ["ls", "/var/log/pods"],
        "volumeMounts": [{"name": "logs", "mountPath": "/var/log/pods"}]
      }]
    }
  }' \
  -n observability
```

**What this does:** Mounts the host's `/var/log/pods` directory into a temporary busybox container
and lists its contents. Used to verify that log files exist for the OTel filelog receiver to read.

**What to look for:** Directories named `<namespace>_<pod-name>_<uid>/` — one per running pod.
If the directory is empty, the filelog receiver has nothing to collect.

### Test DNS resolution from inside the cluster

```bash
kubectl run dns-test --rm -it --restart=Never \
  --image=busybox:1.36 -- nslookup gitea.test
# Expected: Address: <TRAEFIK_CLUSTERIP>
# If "no such host": CoreDNS rewrite rule missing — run coredns-patch.sh
```

Test any internal service name:

```bash
kubectl run dns-test --rm -it --restart=Never \
  --image=busybox:1.36 -- nslookup gitea-http.gitea.svc.cluster.local
# Expected: resolves to a ClusterIP
```

**Why this matters:** There are three DNS contexts in this stack (host, cluster, k3d nodes).
Pods use cluster DNS. k3d nodes use node-level `/etc/hosts`. Confusion between these
contexts is the most common source of mysterious connectivity failures.

### Test Gitea registry from inside the cluster

```bash
kubectl run registry-test --rm -it --restart=Never \
  --image=curlimages/curl:latest \
  -n sensor-dev -- \
  curl -sk -o /dev/null -w "%{http_code}" \
  https://gitea.test/v2/
# 401 = registry reachable, credentials needed (correct)
# 000 = DNS failure or network unreachable
```

### Test gRPC port reachability

OTLP uses gRPC on port 4317. A regular HTTP GET to a gRPC port returns a non-200 response,
but any response (even `400` or `405`) confirms the port is open:

```bash
kubectl run grpc-test --rm -it --restart=Never \
  --image=curlimages/curl:latest \
  -n traefik -- \
  curl -sk -o /dev/null -w "%{http_code}" \
  http://otel-collector-gateway.observability.svc.cluster.local:4317
# 405 or 400 = port is open and responding (gRPC speaks HTTP/2, not HTTP/1.1)
# 000 = port not reachable
```

---

## Part 4 — Certificate and TLS debugging

### Check certificate status

```bash
kubectl get certificate -A
```

**What to look for:** `READY: True` for all certificates.
`READY: False` means cert-manager hasn't issued the cert yet — check why.

```bash
# Get details on a specific certificate
kubectl describe certificate <cert-name> -n <namespace>
```

### Check certificate requests

```bash
kubectl describe certificaterequest -n <namespace>
```

**What this does:** Shows the individual signing requests cert-manager sent to Vault.
**What to look for:**
- `Status: True, Type: Ready` = issued successfully
- `Status: False` = failed — read the `Message` field for the reason
- `WaitingForApproval` events are normal and resolve quickly

**"Optimistic locking" errors in cert-manager logs are NOT a problem:**

```
"re-queuing item due to optimistic locking on resource"
```

This means cert-manager saw a resource change mid-flight and retried.
It's a normal concurrency pattern, not an error.

### Inspect a TLS certificate

Check what CA issued a certificate and when it expires:

```bash
kubectl get secret <secret-name> -n <namespace> \
  -o jsonpath='{.data.tls\.crt}' \
  | base64 -d \
  | openssl x509 -noout -text \
  | grep -A2 "Issuer:\|Subject:\|Validity\|DNS"
```

**What to look for:**
- `Issuer: CN=PoC Intermediate CA` = Vault issued it correctly
- `Not After` = expiry date (certs are 72h, renewed at 48h)
- `DNS:whoami.test` = the hostname is covered by the cert

### Check ClusterIssuer connectivity to Vault

```bash
kubectl get clusterissuer vault-issuer -o wide
```

**What to look for:** `READY: True` with a `Vault verified` message.
If `READY: False`, cert-manager can't reach Vault — check the port-forward.

---

## Part 5 — Vault debugging

### Check Vault status

```bash
# Via port-forward (requires pf-vault running)
curl -s http://127.0.0.1:8200/v1/sys/seal-status | jq .

# Via kubectl exec into the Vault pod
kubectl exec vault-0 -n vault -- vault status
```

**What to look for:** `"sealed": false`. If sealed, the PKI is unavailable and
cert-manager will fail to issue certificates.

**In dev mode, Vault unseals automatically on startup.** If it's sealed, the pod
probably just restarted — run `vault-init.sh` to rebuild the PKI.

### Check Vault PKI is configured

```bash
# In a toolkit session or via vault-poc alias
vault-poc secrets list
```

**What to look for:** `pki/` and `pki_int/` in the list.
If missing, vault-init.sh hasn't run or Vault restarted and lost its in-memory state.

### Retrieve secrets from Vault

```bash
# Full secret record
vault-poc kv get secret/observability/elasticsearch

# IMPORTANT: Never use -field= for scripting — Vault CLI adds ANSI codes
# that corrupt the value in shell variables.
# Always use the Vault UI copy button for manual use, or the k8s secret for scripts.
```

**Why the Vault CLI corrupts passwords in scripts:**
When piped to a variable, `vault kv get -field=password` wraps the value in
ANSI terminal color escape codes (`\033[0m`). The password appears correct
when printed but fails authentication because the escape codes are included.

**Safe pattern for scripting:**

```bash
# Pull directly from the k8s secret — always clean
ES_PASS=$(kubectl get secret elasticsearch-es-elastic-user \
  -n observability -o jsonpath='{.data.elastic}' | base64 -d | tr -d '\r\n')
```

---

## Part 6 — Elasticsearch debugging

All ES API commands assume `pf-es` is running and `ES_PASS` is set:

```bash
ES_PASS=$(kubectl get secret elasticsearch-es-elastic-user \
  -n observability -o jsonpath='{.data.elastic}' | base64 -d | tr -d '\r\n')
```

### Check cluster health

```bash
curl -sk -u "elastic:${ES_PASS}" \
  "https://127.0.0.1:9200/_cluster/health" | jq .
```

**Key fields:**
- `status: green` = all shards allocated, fully operational
- `status: yellow` = primary shards allocated but replicas are not
  (expected on single-node — fix by setting `number_of_replicas: 0`)
- `status: red` = primary shards missing — data may be unavailable

### List all indices

```bash
curl -sk -u "elastic:${ES_PASS}" \
  "https://127.0.0.1:9200/_cat/indices?v&s=index"
```

**Column meanings:**
- `health` = green/yellow/red
- `status` = open/close
- `index` = index name (`.ds-` prefix = data stream backing index)
- `docs.count` = number of documents
- `store.size` = disk usage

### List data streams

Data streams are the logical name (`logs-generic.otel-default`).
Each data stream is backed by one or more physical indices (`.ds-logs-generic.otel-default-*`).

```bash
curl -sk -u "elastic:${ES_PASS}" \
  "https://127.0.0.1:9200/_data_stream/*" | jq '.[].name'
```

### Check index templates

Index templates define the mapping and settings for new indices.
The OTel exporter creates data streams automatically — no template is required.
Custom templates can *conflict* with the exporter's schema and cause errors.

```bash
# List all custom templates
curl -sk -u "elastic:${ES_PASS}" \
  "https://127.0.0.1:9200/_index_template" | jq '[.index_templates[].name]'

# Get a specific template
curl -sk -u "elastic:${ES_PASS}" \
  "https://127.0.0.1:9200/_index_template/metrics-otel" | jq .
```

### Check the mapping of an index

The mapping defines what field types ES expects. Conflicts cause `document_parsing_exception`.

```bash
curl -sk -u "elastic:${ES_PASS}" \
  "https://127.0.0.1:9200/.ds-metrics-generic.otel-default-*/_mapping" \
  | jq '.[] .mappings.properties | keys'
```

**What to look for:** If you see a small set of fields like `["@timestamp", "name", "value"]`
instead of a rich set of OTel fields, the index was created from a test document
(or wrong first write) and the mapping is poisoned.

**Fix — delete the data stream and let it be recreated:**

```bash
curl -sk -u "elastic:${ES_PASS}" \
  -X DELETE "https://127.0.0.1:9200/_data_stream/metrics-generic.otel-default" \
  | jq .acknowledged
```

### Fix yellow indices (replicas)

Single-node ES cannot allocate replica shards — indices stay yellow until replicas are set to 0:

```bash
curl -sk -u "elastic:${ES_PASS}" \
  -X PUT "https://127.0.0.1:9200/<index-name>/_settings" \
  -H "Content-Type: application/json" \
  -d '{"index.number_of_replicas": 0}' | jq .acknowledged
```

**Why this happens:** ECK defaults to 1 replica. A replica requires a second node
to be allocated. With one node, the replica shard has nowhere to go — yellow status.

### Query a document to check data format

```bash
curl -sk -u "elastic:${ES_PASS}" \
  "https://127.0.0.1:9200/traces-generic.otel-default/_search?size=1" \
  | jq '.hits.hits[0]._source'
```

**What this does:** Fetches one document from the traces index so you can see
the actual field structure the OTel exporter wrote.

### Count documents by index

```bash
curl -sk -u "elastic:${ES_PASS}" \
  "https://127.0.0.1:9200/traces-generic.otel-default/_count" | jq .count
```

### Bulk API error decoding

When the OTel exporter fails to index, it logs truncated error messages.
Get the full error by posting directly to the bulk API:

```bash
curl -sk -u "elastic:${ES_PASS}" \
  -X POST "https://127.0.0.1:9200/_bulk" \
  -H "Content-Type: application/json" \
  -d '{"create":{"_index":"metrics-generic.otel-default"}}
{"@timestamp":"2026-01-01T00:00:00Z","test":"value"}
' | jq '.items[0].create'
```

**What to look for in the response:**
- `"result": "created"` = success
- `"error.type": "document_parsing_exception"` = mapping conflict
- `"error.type": "version_conflict_engine_exception"` = duplicate document
  (normal/expected with cumulative metrics in ecs mode)
- `"error.type": "index_not_found_exception"` = data stream doesn't exist yet

---

## Part 7 — OTel Collector debugging

### Check gateway logs for errors

```bash
kubectl logs deployment/otel-collector-gateway \
  -n observability --since=5m | grep -E "error|warn" | head -20
```

**Common errors and what they mean:**

| Error | Cause | Fix |
|-------|-------|-----|
| `index_not_found_exception ... requires data stream` | Collector writing to wrong index name — ConfigMap has custom index names | Re-apply `otel-gateway-config.yaml` |
| `document_parsing_exception` | Data stream mapping conflict | Delete the data stream, restart gateway |
| `version_conflict_engine_exception` | Duplicate metric document | Expected with cumulative metrics — not a problem |
| `dropping cumulative temporality histogram` | Traefik histograms use cumulative temporality which ecs mode can't handle | Expected — these metrics are dropped, others flow fine |
| `retry::max_requests has been deprecated` | Config uses deprecated field | Harmless deprecation warning |

### Verify the gateway is receiving data

The gateway logs nothing when idle — silence means either no data is arriving
or everything is working fine. Distinguish them:

```bash
# Check if the gateway has started and loaded config correctly
kubectl logs deployment/otel-collector-gateway \
  -n observability | grep -i "start\|Everything\|listen" | head -10
```

### Check what config the running pod is actually using

This is critical — the pod may be running a stale ConfigMap if the rollout
didn't pick up the update:

```bash
kubectl exec deployment/otel-collector-gateway \
  -n observability -- cat /conf/config.yaml
```

**If exec fails** (distroless image), check indirectly:

```bash
kubectl get configmap otel-collector-gateway-config \
  -n observability -o jsonpath='{.data.config\.yaml}' \
  | grep -E "index|mapping|endpoint"
```

**Then force a pod restart** to pick up any ConfigMap changes:

```bash
kubectl rollout restart deployment/otel-collector-gateway -n observability
```

### Verify DaemonSet is running on all nodes

```bash
kubectl get pods -n observability -l app=otel-collector-daemonset -o wide
```

**What to look for:** One pod per node (`k3d-poc-server-0`, `k3d-poc-agent-0`, `k3d-poc-agent-1`).
`NODE` column shows which node each pod is on.

### Check DaemonSet configmap version

The DaemonSet configmap went through multiple revisions during this PoC.
The wrong version causes silent log collection failure:

```bash
kubectl get configmap otel-collector-daemonset-config \
  -n observability -o jsonpath='{.data.config\.yaml}' \
  | grep -E "receivers:|kubeletstats|prometheus"
```

**What to look for:**
- `prometheus:` = correct (uses read-only kubelet port, no auth needed)
- `kubeletstats:` = wrong (uses :10250 which returns 401 in k3d)

**Fix:**

```bash
kubectl apply -f /work/otel-daemonset-config.yaml
kubectl rollout restart daemonset/otel-collector-daemonset -n observability
```

### Why the DaemonSet produces no stdout logs

The OTel collector contrib image (`otel/opentelemetry-collector-contrib`) is
distroless — it has no shell and the collector process writes nothing to stdout
unless there's an error. Silent logs from a Running pod are normal.

To confirm the collector is actually processing data, check the gateway instead —
if the gateway is receiving data, the DaemonSet is forwarding it.

---

## Part 8 — Traefik debugging

### Check Traefik routing

```bash
# See all active routes
kubectl get ingress -A
kubectl get ingressroute -A
```

**Ingress** = standard Kubernetes routing resource
**IngressRoute** = Traefik-native CRD (required for ECK backends and internal services)

**Rule of thumb for this stack:**
- Apps (whoami, httpbin) → standard `Ingress`
- Traefik dashboard, Kibana → `IngressRoute` CRD

### Verify Traefik OTel args

The `tracing:` and `metrics.otlp:` Helm values are silently ignored in chart 39.0.5.
OTel must be set via `additionalArguments`. Verify the running pod has them:

```bash
kubectl get pod -n traefik -l app.kubernetes.io/name=traefik \
  -o jsonpath='{.items[0].spec.containers[0].args}' \
  | tr ',' '\n' | grep -i otlp
```

**Expected output** (8 lines):

```
"--tracing.otlp=true"
"--tracing.otlp.grpc=true"
"--tracing.otlp.grpc.endpoint=otel-collector-gateway.observability.svc.cluster.local:4317"
"--tracing.otlp.grpc.insecure=true"
"--metrics.otlp=true"
"--metrics.otlp.grpc=true"
"--metrics.otlp.grpc.endpoint=otel-collector-gateway.observability.svc.cluster.local:4317"
"--metrics.otlp.grpc.insecure=true"
```

**If empty:** Traefik wasn't restarted after the Helm upgrade, or the upgrade didn't apply.

```bash
helm upgrade traefik traefik/traefik \
  --namespace traefik \
  --values /work/traefik-values.yaml

kubectl rollout restart deployment/traefik -n traefik
```

### Debug a 500 error from Traefik

```bash
# Make a request and grab logs immediately
curl -sk https://kibana.test > /dev/null
kubectl logs deployment/traefik -n traefik --since=5s | tail -10
```

**Common 500 causes:**

| Log message | Cause | Fix |
|-------------|-------|-----|
| `x509: cannot validate certificate for ... IP SANs` | Traefik verifying ECK's self-signed cert | Use IngressRoute + ServersTransport CRD |
| `connection refused` | Backend pod not running | Check backend pod status |
| `no such host` | Service DNS name wrong | Check service name with `kubectl get svc -n <ns>` |

### Check ServersTransport is registered (for Kibana)

```bash
kubectl get serversTransport -n observability
```

**What this is:** A Traefik CRD that tells Traefik how to connect to a backend.
The `insecuretransport` ServersTransport tells Traefik to skip TLS verification
when connecting to Kibana's ECK-managed self-signed certificate.

**Why IngressRoute instead of Ingress for Kibana:**
Standard Kubernetes Ingress resources don't reliably apply ServersTransport
annotations in Traefik v3. IngressRoute CRDs have a native `serversTransport`
field that works correctly.

---

## Part 9 — Common patterns that tripped us up

These are issues that caused repeated debugging cycles in this build.
Documented here so they're recognizable next time.

### Pattern 1 — ConfigMap applied but pod uses old version

**Symptom:** You applied a ConfigMap fix but the problem persists.
**Cause:** Kubernetes doesn't automatically restart pods when a ConfigMap changes.
**Fix:** Always restart the workload after changing a ConfigMap:

```bash
kubectl apply -f /work/<config>.yaml
kubectl rollout restart deployment/<name> -n <namespace>
# or
kubectl rollout restart daemonset/<name> -n <namespace>
```

**Verify the pod is running the new config:**

```bash
# Check what the running pod actually has mounted
kubectl exec deployment/<name> -n <namespace> -- cat /conf/config.yaml
```

### Pattern 2 — Data stream created before index template

**Symptom:** `document_parsing_exception` on a data stream that was previously working.
**Cause:** The OTel collector wrote the first document before index templates existed,
or after an ILM rollover created a new backing index with a stale/missing template.
ES created the data stream with wrong field mappings and subsequent writes fail.

**Fix:**

```bash
# 1. Delete the entire data stream (not just the backing index)
curl -sk -u "elastic:${ES_PASS}" \
  -X DELETE "https://127.0.0.1:9200/_data_stream/<signal>-generic.otel-default" \
  | docker run --rm -i devops-toolkit:latest jq .acknowledged

# 2. Restart the gateway so it recreates the stream from the correct template
kubectl rollout restart deployment/otel-collector-gateway -n observability
kubectl rollout status deployment/otel-collector-gateway -n observability --timeout=60s
```

> **Important:** Delete the entire data stream, not just the backing index.
> Deleting only the backing index (`.ds-metrics-generic...`) leaves the data
> stream shell intact but with a broken write index — the gateway will
> recreate the backing index with the same bad mapping.

**Prevention:** Run `obs-init` before deploying collectors on a fresh cluster.
The index templates must exist before the first write.

### Pattern 3 — metrics-otel template missing named dynamic templates

**Symptom:** `document_parsing_exception` on `metrics-generic.otel-default` persists
even after deleting and recreating the data stream. Error message from ES debug logs:
`Can't find dynamic template for dynamic template name [counter_double] of field [metrics.traefik_...]`

**Cause:** The ES exporter ECS mode sends metrics documents that reference named
dynamic templates (`counter_double`, `gauge_double`, `counter_long`, `gauge_long`,
`summary_double`) by name in the bulk request. These templates must be explicitly
defined in the index template — ES will not create them automatically, and any
document referencing a missing named template is rejected entirely.

This affects **only the metrics pipeline**. Logs and traces do not use named
dynamic templates and work correctly with `all_strings_as_keyword` alone.

**Diagnosis:**

```bash
# Enable ES bulk action debug logging temporarily
curl -sk -u "elastic:${ES_PASS}" \
  -X PUT "https://127.0.0.1:9200/_cluster/settings" \
  -H "Content-Type: application/json" \
  -d '{"transient": {"logger.org.elasticsearch.action.bulk": "DEBUG"}}' \
  | docker run --rm -i devops-toolkit:latest jq .acknowledged

sleep 15
kubectl logs elasticsearch-es-default-0 -n observability --since=20s \
  | grep "dynamic template" | head -5

# Disable after diagnosis
curl -sk -u "elastic:${ES_PASS}" \
  -X PUT "https://127.0.0.1:9200/_cluster/settings" \
  -H "Content-Type: application/json" \
  -d '{"transient": {"logger.org.elasticsearch.action.bulk": null}}' \
  | docker run --rm -i devops-toolkit:latest jq .acknowledged
```

**Fix:** The `metrics-otel` index template must include all named dynamic templates.
This is handled correctly in the current `obs-init.sh`. If the template is missing
them (e.g., after a manual template update), re-run `obs-init` then delete and
recreate the data stream:

```bash
obs-init   # recreates metrics-otel template with correct named dynamic templates

curl -sk -u "elastic:${ES_PASS}" \
  -X DELETE "https://127.0.0.1:9200/_data_stream/metrics-generic.otel-default" \
  | docker run --rm -i devops-toolkit:latest jq .acknowledged

kubectl rollout restart deployment/otel-collector-gateway -n observability
```

**Why logs and traces are unaffected:** The ES exporter only uses named dynamic
templates for metric types (counters, gauges, summaries). Span and log documents
use standard dynamic field mapping which ES handles automatically.

### Pattern 4 — Vault CLI ANSI codes corrupt passwords in scripts

**Symptom:** `vault kv get -field=password` works interactively but returns 401
when the value is used in a curl command.

**Cause:** The Vault CLI wraps field output in ANSI terminal escape codes
(`\033[0m`). These are invisible when printed to a terminal but are included
in the string when captured with `$()`.

**Diagnosis:**

```bash
vault-poc kv get -field=password secret/observability/elasticsearch | od -c | head -3
# Look for 033 [ 0 m at the start and end — those are the escape codes
```

**Fix:** Always use the k8s secret directly for scripting:

```bash
ES_PASS=$(kubectl get secret elasticsearch-es-elastic-user \
  -n observability -o jsonpath='{.data.elastic}' | base64 -d | tr -d '\r\n')
```

Use the Vault UI copy button for manual password retrieval.

### Pattern 5 — otel-daemonset.yaml contained a stale embedded ConfigMap

**Symptom:** After rebuild, the DaemonSet uses the old `kubeletstats` config
instead of the correct `prometheus` config, causing silent log collection failure.

**Cause:** `otel-daemonset.yaml` originally contained the ConfigMap definition
inline. When applied, it overwrote the correct `otel-daemonset-config.yaml`.

**Prevention:** `otel-daemonset.yaml` and `otel-gateway.yaml` must contain
ONLY the workload resources — no ConfigMaps. Always apply ConfigMap files
before workload files:

```bash
kubectl apply -f /work/otel-gateway-config.yaml    # ConfigMap first
kubectl apply -f /work/otel-gateway.yaml            # then workload
kubectl apply -f /work/otel-daemonset-config.yaml   # ConfigMap first
kubectl apply -f /work/otel-daemonset.yaml          # then workload
```

**Verify a file doesn't contain embedded ConfigMaps:**

```bash
grep -n "kind: ConfigMap" ~/Projects/poc/manifests/otel-daemonset.yaml
grep -n "kind: ConfigMap" ~/Projects/poc/manifests/otel-gateway.yaml
# Both should return nothing
```

### Pattern 6 — kubeletstats receiver returns 401 in k3d

**Symptom:** DaemonSet pods run silently with no metrics output.
**Cause:** The `kubeletstats` receiver connects to `https://NODE_IP:10250`.
In k3d/k3s, the kubelet webhook authenticator rejects serviceAccount tokens
for direct kubelet API calls even when the API server RBAC permits it.

**Diagnosis:**

```bash
kubectl run kubelet-test --rm -it --restart=Never \
  --image=curlimages/curl:latest \
  -n observability -- \
  curl -sk -o /dev/null -w "%{http_code}" \
  "https://<node-ip>:10250/healthz"
# 401 = port reachable but auth rejected
# 000 = port not reachable
```

**Fix:** Use the Prometheus receiver with the read-only kubelet port instead:

```yaml
prometheus:
  config:
    scrape_configs:
    - job_name: kubelet
      scheme: http
      static_configs:
      - targets:
        - ${env:K8S_NODE_IP}:10255   # read-only port, no auth
      metrics_path: /metrics
```

### Pattern 7 — Traefik OTel Helm values silently ignored

**Symptom:** Traefik doesn't send traces or metrics to the OTel gateway.
**Cause:** The `tracing:` and `metrics.otlp:` keys in the Helm values file
are not translated into CLI args by chart version 39.0.5.

**Diagnosis:**

```bash
kubectl get pod -n traefik -l app.kubernetes.io/name=traefik \
  -o jsonpath='{.items[0].spec.containers[0].args}' \
  | tr ',' '\n' | grep -i otlp
# Empty = Helm values weren't applied as CLI args
```

**Fix:** Use `additionalArguments` in the Helm values file instead of the
structured `tracing:` and `metrics.otlp:` sections.

### Pattern 8 — ILM rollover causes version_conflict_engine_exception on metrics

**Symptom:** After an ILM rollover, the gateway logs flood with
`version_conflict_engine_exception` on the old metrics backing index, and the
new backing index stays at 0 documents.

**Cause:** The ES exporter caches the write index name internally. After ILM
rolls over to a new backing index, the exporter keeps trying to write to the
now read-only old index. A gateway restart is supposed to fix this but doesn't
always — if the new backing index was created during the rollover with a bad
mapping (e.g., from a manual rollover before the template was correct), the
gateway will switch to `document_parsing_exception` on the new index instead.

**Fix:**

```bash
# Step 1 — manually trigger rollover if stuck (only if ILM hasn't already rolled)
curl -sk -u "elastic:${ES_PASS}" \
  -X POST "https://127.0.0.1:9200/metrics-generic.otel-default/_rollover" \
  | docker run --rm -i devops-toolkit:latest jq '{acknowledged, rolled_over, new_index}'

# Step 2 — delete the entire data stream to force clean recreation
curl -sk -u "elastic:${ES_PASS}" \
  -X DELETE "https://127.0.0.1:9200/_data_stream/metrics-generic.otel-default" \
  | docker run --rm -i devops-toolkit:latest jq .acknowledged

# Step 3 — restart gateway to pick up the clean new stream
kubectl rollout restart deployment/otel-collector-gateway -n observability
kubectl rollout status deployment/otel-collector-gateway -n observability --timeout=60s
```

**Prevention:** The ILM rollover issue is inherent to the ES exporter v0.123.0.
If metrics go missing after 2h, this is the first thing to check. The data stream
delete + gateway restart is the reliable recovery path.

### Pattern 9 — Scripts failing with VAULT_TOKEN="root"

**Symptom:** Scripts exit with `Could not retrieve ES password from Vault` or
similar Vault 403 errors even though Vault is reachable and the token is valid.

**Cause:** Some scripts had `VAULT_TOKEN="root"` hardcoded. The actual root token
is a real token stored in `${POC_DIR}/vault/root-token`, not the literal string "root".

**Fix:** All scripts now read the token from file:

```bash
VAULT_TOKEN=$(cat "${HOME}/Projects/poc/vault/root-token" 2>/dev/null | tr -d '%\n')
```

The `tr -d '%\n'` strips the trailing `%` that zsh appends when there's no newline,
and any newline characters. If a script fails with Vault 403, check its `VAULT_TOKEN`
line — hardcoded `"root"` is the tell.

---

When something isn't working, run through this in order:

```bash
# 1. Are all pods running?
kubectl get pods -n <namespace>

# 2. Any recent events?
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -10

# 3. What do the logs say?
kubectl logs deployment/<name> -n <namespace> --since=2m | grep -E "error|warn"

# 4. Is the config correct on the running pod?
kubectl get configmap <name> -n <namespace> -o jsonpath='{.data.config\.yaml}' \
  | grep -E "endpoint|index|mapping"

# 5. Can the pod reach its dependencies?
kubectl run test --rm -it --restart=Never \
  --image=curlimages/curl:latest \
  -n <namespace> -- \
  curl -sk -o /dev/null -w "%{http_code}" <dependency-url>

# 6. Is ES healthy?
curl -sk -u "elastic:${ES_PASS}" "https://127.0.0.1:9200/_cluster/health" | jq .status

# 7. Are data streams receiving data?
curl -sk -u "elastic:${ES_PASS}" \
  "https://127.0.0.1:9200/_cat/indices?v&s=index&h=index,health,docs.count" \
  | grep "generic.otel"
```

---

## Reference — service names and ports

| Service | Namespace | Port | Protocol |
|---------|-----------|------|----------|
| vault | vault | 8200 | HTTP |
| elasticsearch-es-http | observability | 9200 | HTTPS |
| kibana-kb-http | observability | 5601 | HTTPS |
| otel-collector-gateway | observability | 4317 | gRPC (OTLP) |
| otel-collector-gateway | observability | 4318 | HTTP (OTLP) |
| otel-collector-daemonset | observability | 4317 | gRPC (OTLP) |
| traefik | traefik | 80/443 | HTTP/HTTPS |
| cert-manager | cert-manager | 9402 | HTTP (Prometheus metrics) |
| mosquitto | messaging | 1883 | MQTT |
| redis | messaging | 6379 | Redis |
| kafka | messaging | 9092 | Kafka (SASL/PLAIN) |
| gitea-http | gitea | 3000 | HTTP (internal cluster use) |
| gitea (via Traefik) | — | 443 | HTTPS (gitea.test) |
| sensor-producer | sensor-dev | — | no inbound port |
| mqtt-bridge | sensor-dev | — | no inbound port |
| event-consumer | sensor-dev | — | no inbound port |

### Pattern 10 — ImagePullBackOff: authorization failed, no basic auth credentials

**Symptom:** Pods stuck in `ImagePullBackOff` with event:
`authorization failed: no basic auth credentials`

**Cause 1 — Secret server mismatch:** The `gitea-registry` imagePullSecret was
created with `--docker-server=gitea-http.gitea.svc.cluster.local:3000` but images
are tagged `gitea.test/poc/<app>:<sha>`. containerd silently ignores credentials
when the server URL doesn't match the image registry prefix.

**Diagnosis:**
```bash
kubectl get secret gitea-registry -n sensor-dev \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq .
# The "auths" key must be "gitea.test" — not the internal cluster URL
```

**Fix:**
```bash
GITEA_PASS=$(gitea-token)
for NS in sensor-dev sensor-qa sensor-prod; do
  kubectl create secret docker-registry gitea-registry \
    -n ${NS} \
    --docker-server=gitea.test \
    --docker-username=poc-admin \
    --docker-password="${GITEA_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f -
done
kubectl delete pods -n sensor-dev --all
```

**Cause 2 — imagePullSecrets not on ServiceAccount:** The secret exists but isn't
referenced by the ServiceAccount the pods use.

```bash
kubectl get serviceaccount sensor-producer -n sensor-dev -o yaml | grep -A3 imagePull
# Expected: imagePullSecrets: - name: gitea-registry
```

**Fix:**
```bash
for SA in sensor-producer mqtt-bridge event-consumer; do
  kubectl patch serviceaccount ${SA} -n sensor-dev \
    --patch '{"imagePullSecrets": [{"name": "gitea-registry"}]}'
done
kubectl delete pods -n sensor-dev --all
```

### Pattern 11 — ImagePullBackOff: lookup gitea.test: no such host (k3d nodes)

**Symptom:** Pods stuck in `ImagePullBackOff` with event:
`failed to pull image "gitea.test/poc/...": failed to resolve reference "gitea.test/...": lookup gitea.test: no such host`

**Cause:** containerd on k3d nodes uses the node's `/etc/hosts` for DNS resolution —
not cluster DNS. The CoreDNS rewrite rule does not help here. After a cluster restart
the ephemeral `/etc/hosts` entries on each node are lost.

**Fix:**
```bash
TRAEFIK_IP=$(kubectl get svc traefik -n traefik -o jsonpath='{.spec.clusterIP}')
for NODE in k3d-poc-server-0 k3d-poc-agent-0 k3d-poc-agent-1; do
  docker exec ${NODE} sh -c "echo '${TRAEFIK_IP} gitea.test' >> /etc/hosts"
done
kubectl delete pods -n sensor-dev --all
```

Or re-run `coredns-patch.sh` which does this automatically:
```bash
bash ${POC_DIR}/scripts/coredns-patch.sh
```

### Pattern 12 — Silent pipeline: traces from sensor-producer only, none from mqtt-bridge or event-consumer

**Symptom:** Elasticsearch has traces for `sensor-producer` but nothing from `mqtt-bridge`
or `event-consumer`. Both pods are Running 2/2.

**Cause:** sensor-producer is publishing to a different MQTT topic than mqtt-bridge is
subscribed to. The Mosquitto broker receives messages but has no subscribers for that topic.

**Diagnosis:**
```bash
# Check what topic sensor-producer is actually publishing to
kubectl logs -n sensor-dev \
  $(kubectl get pod -n sensor-dev -l app=sensor-producer \
    -o jsonpath='{.items[0].metadata.name}') \
  -c sensor-producer --tail=5
# Look for: Published sensorId=... (confirms publishing)

# Check mosquitto broker — is it routing to mqtt-bridge?
kubectl logs -n messaging \
  $(kubectl get pod -n messaging -l app=mosquitto \
    -o jsonpath='{.items[0].metadata.name}') --tail=20
# Look for: "Sending PUBLISH to mqtt-bridge-..." lines
# If only "Received PUBLISH" with no "Sending PUBLISH" → no subscribers for that topic

# Check what topic mqtt-bridge is subscribed to
kubectl logs -n sensor-dev \
  $(kubectl get pod -n sensor-dev -l app=mqtt-bridge \
    -o jsonpath='{.items[0].metadata.name}') \
  -c mqtt-bridge --tail=10
# Look for: Subscribed to MQTT topic: sensors/temperature

# Check the ConfigMap value
kubectl get configmap sensor-config -n sensor-dev -o yaml | grep MQTT_TOPIC
```

**Fix:** `MQTT_TOPIC` in the ConfigMap and the topic sensor-producer publishes to must match.
sensor-producer reads `MQTT_TOPIC` from its environment. If it's using a hardcoded topic,
the `Program.cs` needs updating.

### Pattern 13 — CI workflow fails with exit code 60 (SSL error)

**Symptom:** `Update image tag in deploy repo` step fails with exit code 60.
Exit code 60 = curl SSL certificate problem.

**Cause:** The Vault-issued CA cert is mounted into job containers but not installed
into the system trust store. curl and git use the system trust store by default.

**Fix:** `update-ca-certificates` must be an explicit step in the workflow BEFORE
any SSL operations (git clone, curl to gitea.test):

```yaml
- name: Install CA certificate
  run: update-ca-certificates
```

This step must run before: `docker login`, `git clone`, `curl` to any `.test` URL,
and kustomize download. The CA cert is at
`/usr/local/share/ca-certificates/poc-ca.crt` (mounted by the runner config).

Additionally, the kustomize download curl should use `--cacert` explicitly as a
belt-and-suspenders approach:
```bash
curl -sL --cacert /usr/local/share/ca-certificates/poc-ca.crt \
  "https://github.com/.../kustomize_vX.X.X_linux_amd64.tar.gz" \
  -o /tmp/kustomize.tar.gz
```

---

When something isn't working, run through this in order:

#poc #k3d #troubleshooting #elasticsearch #opentelemetry #traefik #vault
