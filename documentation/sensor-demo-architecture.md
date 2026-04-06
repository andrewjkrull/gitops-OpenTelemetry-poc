# Sensor Demo — Architecture and OTel Story

## What this demo shows

Three .NET 6 microservices communicate across MQTT, Redis, and Kafka. Every
message carries a W3C trace context header. OpenTelemetry captures every span
from every service and ships it to Elasticsearch. Kibana shows the complete
journey of a single sensor reading — from the moment it was published to the
moment it was consumed — as one unified trace across three services and four
infrastructure components.

The GitOps layer makes it operational: a single config change in a Git repo
propagates to the cluster automatically, and the new behaviour appears in
Kibana within seconds.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  sensor-dev namespace                                            │
│                                                                  │
│  ┌──────────────────┐                                           │
│  │  sensor-producer  │  Every N seconds (SENSOR_INTERVAL_MS):  │
│  │                   │  1. Start root OTel span                 │
│  │  ServiceAccount:  │  2. Cache reading in Redis               │
│  │  sensor-producer  │  3. Publish to MQTT with traceparent     │
│  └────────┬──────────┘                                          │
│           │ MQTT: sensors/reading                               │
│           │ (message contains W3C traceparent)                  │
│           ▼                                                      │
│  ┌──────────────────┐                                           │
│  │   mqtt-bridge    │  For each MQTT message:                   │
│  │                  │  1. Extract traceparent → child span      │
│  │  ServiceAccount: │  2. Read previous value from Redis        │
│  │  mqtt-bridge     │  3. Calculate delta and trend             │
│  └────────┬─────────┘  4. Publish enriched event to Kafka      │
│           │ Kafka: sensor-events                                │
│           │ (message contains updated traceparent)             │
│           ▼                                                      │
│  ┌──────────────────┐                                           │
│  │  event-consumer  │  For each Kafka message:                  │
│  │                  │  1. Extract traceparent → child span      │
│  │  ServiceAccount: │  2. Write result to Redis                 │
│  │  event-consumer  │  3. Log with traceId embedded             │
│  └──────────────────┘                                           │
│                                                                  │
│  All three pods: 2/2 (app + vault-agent sidecar)                │
│  Vault Agent writes secrets to /vault/secrets/ at pod start     │
└─────────────────────────────────────────────────────────────────┘
         │ OTLP gRPC (all three services)
         ▼
┌─────────────────────────────────────────────────────────────────┐
│  observability namespace                                         │
│                                                                  │
│  OTel Collector Gateway ──► Elasticsearch ──► Kibana            │
│                                                                  │
│  Data streams:                                                   │
│    traces-generic.otel-default   ← spans from all three apps    │
│    logs-generic.otel-default     ← structured logs (with traceId)│
│    metrics-generic.otel-default  ← runtime + Traefik metrics    │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  messaging namespace                                             │
│                                                                  │
│  Mosquitto (MQTT)   — sensor-producer → mqtt-bridge             │
│  Redis              — cache + delta enrichment + results        │
│  Kafka (KRaft)      — mqtt-bridge → event-consumer             │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  GitOps layer                                                    │
│                                                                  │
│  Gitea (gitea.test)                                             │
│    poc/sensor-demo-deploy ──► ArgoCD watches this repo          │
│      base/configmap.yaml  ←── THIS IS THE DEMO KNOB            │
│      envs/dev/            ──► sensor-demo-dev (auto-sync)       │
│      envs/qa/             ──► sensor-demo-qa  (manual)          │
│      envs/prod/           ──► sensor-demo-prod (manual)         │
│                                                                  │
│  ArgoCD (argocd.test)                                           │
│    sensor-demo-dev: Synced, Healthy, auto-sync                  │
│    sensor-demo-qa:  OutOfSync (awaiting promotion)              │
│    sensor-demo-prod: OutOfSync (awaiting promotion)             │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  vault namespace                                                 │
│                                                                  │
│  Vault Agent Injector webhook intercepts pod creation           │
│  Reads pod annotations → authenticates via ServiceAccount       │
│  Writes secrets to /vault/secrets/ before app container starts  │
│                                                                  │
│  secret/apps/mqtt   → sensor-producer, mqtt-bridge              │
│  secret/apps/redis  → sensor-producer, mqtt-bridge, event-consumer│
│  secret/apps/kafka  → mqtt-bridge, event-consumer               │
│                                                                  │
│  Least privilege: each app only has access to what it needs     │
└─────────────────────────────────────────────────────────────────┘
```

---

## The trace chain

This is the core of the demo. One sensor reading produces one trace ID that
appears as a single unified trace in Kibana, with child spans from every
service that touched it.

```
Trace: 4bf92f3577b34da6a3ce929d0e0e4736
│
├── publish-sensor-reading          [sensor-producer]  ~2ms
│   ├── redis-cache-write           [sensor-producer]  ~1ms
│   └── mqtt-publish                [sensor-producer]  ~1ms
│
├── bridge-sensor-reading           [mqtt-bridge]      ~5ms
│   ├── redis-enrich                [mqtt-bridge]      ~1ms  (delta lookup)
│   └── kafka-publish               [mqtt-bridge]      ~3ms
│
└── consume-sensor-event            [event-consumer]   ~2ms
    └── redis-result-write          [event-consumer]   ~1ms
```

**What you can show with this:**
- Total end-to-end latency for a sensor reading to be fully processed
- Where time is spent — is Kafka slow? Is Redis slow?
- Which sensor IDs are producing the most events
- Trend distribution — how many readings are rising vs falling vs stable
- Error rates per service — if MQTT or Kafka has issues, the spans show errors

---

## The demo knob

`base/configmap.yaml` in `sensor-demo-deploy` contains:

```yaml
SENSOR_INTERVAL_MS: "1000"   # one reading per second
```

**The demo sequence:**

1. Open Kibana → Traces — note the current event rate
2. Open `https://gitea.test/poc/sensor-demo-deploy` → `base/configmap.yaml`
3. Change `SENSOR_INTERVAL_MS` from `1000` to `500`
4. Commit directly to `main`
5. Watch ArgoCD at `https://argocd.test` — `sensor-demo-dev` syncs in ~30 seconds
6. Return to Kibana — event rate doubles, same trace chain intact

This demonstrates:
- **GitOps:** a Git commit is the only way to change cluster state
- **Observability:** the change is immediately measurable in traces
- **Platform value:** no kubectl, no SSH, no manual deploy

---

## The secret sauce — W3C trace context across non-HTTP protocols

The standard challenge with distributed tracing is that HTTP has headers where
trace context travels naturally. MQTT and Kafka have no such mechanism.

This demo solves it by embedding the W3C `traceparent` directly in the message
JSON payload:

```json
{
  "traceParent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
  "traceState": "",
  "sensorId": "sensor-01",
  "value": 22.4,
  "unit": "celsius",
  "timestamp": "2026-03-23T14:00:00Z"
}
```

Each downstream service:
1. Deserialises the message
2. Calls `Propagator.Extract()` on the `traceparent` field
3. Starts a new span with the extracted context as its parent
4. Embeds the updated `traceparent` in its outbound message

The result: every service in the chain is linked to the same root trace,
regardless of the transport protocol.

---

## What Kibana shows

### Traces view
- Search by `service.name: sensor-producer` — see all root spans
- Click any span — expand to see the full three-service chain
- Filter by `sensor.trend: rising` — see only temperature increases
- Filter by `sensor.id: sensor-01` — track one sensor end to end

### Logs view
- Filter by `body: *trace:*` — see structured logs with traceId embedded
- Copy a traceId from a log entry — paste into Traces search
- One click from log to the full distributed trace

### Correlating logs to traces
Each `event-consumer` log entry contains the first 8 characters of the traceId:
```
[trace:4bf92f35] Consumed event sensorId=sensor-01 value=22.4celsius trend=rising delta=+1.20
```
Search Kibana Traces for the full traceId to see every span that produced
this log entry.

---

## Vault Agent injection — why apps have no credentials in code or config

Every pod in `sensor-dev` runs with two containers:

```
sensor-producer-<hash>   2/2   Running
  ├── sensor-producer    ← your app
  └── vault-agent        ← Vault sidecar (injected by webhook)
```

At pod start:
1. `vault-agent-init` (init container) runs first
2. Authenticates to Vault using the pod's Kubernetes ServiceAccount token
3. Fetches secrets and renders them to `/vault/secrets/*.env`
4. Exits — app container starts with secrets already on disk
5. `vault-agent` sidecar keeps running to renew secrets before they expire

The app reads:
```csharp
foreach (var line in File.ReadAllLines("/vault/secrets/mqtt.env"))
{
    // MQTT_HOST=mosquitto.messaging.svc.cluster.local
    // MQTT_PORT=1883
    // MQTT_USERNAME=sensor
    // MQTT_PASSWORD=<rotated-automatically>
}
```

No secrets in environment variables. No secrets in ConfigMaps. No secrets in
the container image. Every access is audited in Vault's audit log.

---

## Environment progression

| Environment | Namespace | Sync | Purpose |
|-------------|-----------|------|---------|
| dev | sensor-dev | Auto | Changes deploy automatically on push |
| qa | sensor-qa | Manual | Requires explicit approval in ArgoCD UI |
| prod | sensor-prod | Manual | Requires explicit approval in ArgoCD UI |

To promote dev → qa:
1. Open `https://argocd.test`
2. Click `sensor-demo-qa`
3. Click **Sync** → **Synchronize**
4. Pods start in `sensor-qa` with the same config as `sensor-dev`

---

## Service responsibilities summary

| Service | Reads from | Writes to | Vault secrets |
|---------|-----------|-----------|---------------|
| sensor-producer | — | MQTT, Redis | mqtt.env, redis.env |
| mqtt-bridge | MQTT, Redis | Kafka, Redis | mqtt.env, redis.env, kafka.env |
| event-consumer | Kafka | Redis | kafka.env, redis.env |

---

## Production hardening notes (not in scope for PoC)

These are documented so they are not forgotten:

- **Kafka SASL/PLAIN → SASL/SCRAM-SHA-256** — PLAIN is acceptable for in-cluster
  traffic but SCRAM should be used in production
- **Kafka mTLS** — use Vault PKI to issue client certificates for each service
- **OTel sampling** — currently 100% trace sampling; production uses head-based
  or tail-based sampling to reduce volume
- **Kibana alerting** — alert on error rate increase or end-to-end latency
  threshold breach
- **NetworkPolicy** — restrict which pods can reach MQTT, Kafka, Redis
