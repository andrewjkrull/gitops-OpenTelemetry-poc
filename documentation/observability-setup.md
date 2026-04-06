# Phase 5a Runbook — Kibana Dashboards

## Pre-flight verification

The following was verified against live data before building any panels.
Do not skip this if rebuilding from scratch. Full commands are in the **Commands** section at the end of this document.

| # | Check | Ref | Confirmed result |
|---|---|---|---|
| 1 | All observability pods Running | [Check 1](#check-1--observability-pod-status) | elasticsearch, kibana, 3x daemonset, gateway all Running |
| 2 | Traces flowing for all services | [Check 2](#check-2--trace-counts-by-service) | mqtt-bridge ~40k, sensor-producer ~40k, event-consumer ~26k, traefik ~13k |
| 3 | License tier | [Check 3](#check-3--kibana-license-tier) | `basic` — Lens formulas supported |
| 4 | `attributes.sensor.trend` and `sensor.delta` present | [Check 4](#check-4--sensor-fields-on-bridge-spans) | trend values: `rising`, `falling`, `stable`; delta stored as **string keyword** — not float |
| 5 | `status.code` format and values | [Check 5](#check-5--statuscode-values) | String keyword: `Unset` (baseline) and `Error` (confirmed present) |
| 6 | Error spans identity | [Check 6](#check-6--error-span-identity) | 2 Traefik `ReverseProxy` spans, HTTP 401 from ArgoCD UI — not sensor pipeline errors |
| 7 | `body.text` field mapping in logs index | [Check 7](#check-7--bodytext-field-mapping) | Mapped as `keyword` — requires wildcard syntax `body.text:*trace*` in Lucene mode |
| 8 | `trace_id` and `span_id` on log documents | [Check 8](#check-8--trace_id-on-log-documents) | Present as structured keyword fields — OTel logging bridge active on all three apps |

**Key implications:**
- `attributes.sensor.delta` is a string keyword — do not use in numeric Lens aggregations
- Error panel: adding a Traefik exclusion filter causes "No results" when no sensor errors exist, rendering a blank panel. Use `status.code: Error` alone and accept Traefik 401 spikes as background noise
- `body.text` is keyword-mapped — KQL and Lucene full-text search both fail; use `body.text:*trace*` wildcard in Lucene mode
- `trace_id` and `span_id` are now structured keyword fields on log documents — the OTel logging bridge is active on all three sensor apps. Use KQL exact match `trace_id: "<32-char-id>"` for log-to-trace correlation. The `body.text` wildcard approach still works but is no longer needed

---

## Confirmed field names (OTel Collector Contrib 0.123.0, ECS mode, ES 8.17.0)

| Concept | Field | Notes |
|---|---|---|
| Span name | `name` | keyword |
| Duration | `duration` | nanoseconds — divide by 1,000,000 for ms in Lens formulas |
| Service name | `resource.attributes.service.name` | keyword |
| Trace ID | `trace_id` | keyword |
| Span ID | `span_id` | keyword |
| OTel status | `status.code` | keyword: `Unset`, `Ok`, `Error` |
| Sensor ID | `attributes.sensor.id` | keyword |
| Sensor value | `attributes.sensor.value` | float |
| Sensor trend | `attributes.sensor.trend` | keyword: `rising`, `falling`, `stable` — only on `bridge-sensor-reading` spans |
| Sensor delta | `attributes.sensor.delta` | keyword (stored as string — not usable in numeric aggregations) |
| Log body | `body.text` | keyword — use `body.text:*value*` wildcard in Lucene mode |
| Log file path | `attributes.log.file.path` | keyword — use `*appname*` wildcard to identify app |
| Log trace ID | `trace_id` | keyword — structured field on log documents; KQL exact match works |
| Log span ID | `span_id` | keyword — structured field on log documents |
| Log attributes | `attributes.SensorId`, `attributes.Value`, etc. | structured log parameters from .NET logger |
| Timestamp | `@timestamp` | date |

**Confirmed span names from app source:**

| Service | Span name |
|---|---|
| sensor-producer | `publish-sensor-reading` |
| sensor-producer | `redis-cache-write` |
| sensor-producer | `mqtt-publish` |
| mqtt-bridge | `bridge-sensor-reading` |
| mqtt-bridge | `redis-enrich` |
| mqtt-bridge | `kafka-publish` |
| event-consumer | `consume-sensor-event` |
| event-consumer | `redis-result-write` |

---

## Part 1 — Import data views

The `sensor-demo-kibana.ndjson` file pre-creates data views and the dashboard shell.
Import it first to avoid building panels against missing data views.

1. Open `https://kibana.test` and log in (`elastic` / `es-pass`)
2. Navigate to **Stack Management → Saved Objects**
3. Click **Import**
4. Upload `documentation/sensor-demo-kibana.ndjson`
5. Select **Overwrite all** → click **Import**

**Expected result:**

| Object | Expected outcome |
|---|---|
| `Sensor Demo — Observability Overview` (dashboard) | Imported successfully |
| `logs-generic.otel-default` (data view) | Imported successfully |
| `traces-generic.otel-default` (data view) | Imported successfully |
| 4 visualization stubs | Error — expected, safe to ignore |

The 4 visualization stubs (`Service Latency Over Time`, `Event Throughput`, `Sensor Trend Distribution`,
`Error Span Rate Over Time`) will fail with an error in Kibana 8.17. This is expected — the stubs
contain empty Lens state (`aggs: []`) which Kibana 8 rejects as invalid. They are not needed;
all panels are built manually in Lens as described in Part 3. The dashboard shell and both data
views are what matter.

> **If the import shows warnings about `migrationVersion`:** Kibana 8 accepts the 7.x
> index-pattern format on import but upgrades it internally. Warnings are safe to dismiss.
> If data views are missing after import, create them manually (see below).

**Manual data view creation (fallback):**

1. **Stack Management → Data Views → Create data view**
2. Name: `traces-generic.otel-default` / Index pattern: `traces-generic.otel-default` / Timestamp: `@timestamp`
3. Repeat for `logs-generic.otel-default`

---

## Part 2 — Verify data views have correct field mappings

Before building panels, confirm the data views resolved their fields.

1. **Stack Management → Data Views → traces-generic.otel-default**
2. Search for each field: `name`, `duration`, `resource.attributes.service.name`, `status.code`, `attributes.sensor.trend`
3. If any field is missing: click **Refresh field list** (top right of the field list)

> `attributes.sensor.trend` and `attributes.sensor.delta` only exist on `bridge-sensor-reading`
> spans — they are sparse fields and may not appear until Kibana refreshes against recent data.

---

## Part 3 — Build the six panels

Navigate to **Analytics → Dashboards → Sensor Demo — Observability Overview** (imported above)
or create a new dashboard. Set time range to **Last 1 hour** before building panels.

All panels use the **traces-generic.otel-default** data view unless noted.

> **Kibana 8.17 naming notes:** The Y-axis metric formerly called "Count of records" is
> labelled **Count** in 8.17. Use **Count** wherever count of records is specified below.
> All Y-axis metrics that display nanosecond durations must use the **Formula** function
> with `/ 1000000` to convert to milliseconds — the raw **Percentile** function returns
> nanoseconds and will dwarf other metrics on the Y-axis.

---

### Panel 1 — Service Latency Over Time

**Type:** Line chart — shows avg and p95 span duration per service over time.
**Demonstrates:** Which service contributes most latency; how latency changes as you adjust `SENSOR_INTERVAL_MS`.

1. Click **Add panel → Create visualization**
2. Select chart type: **Line**
3. Data view: `traces-generic.otel-default`
4. **X-axis:** `@timestamp` → Date histogram, auto interval
5. **Y-axis (first):**
   - Function: **Formula**
   - Formula: `average(duration) / 1000000`
   - Custom label: `Avg latency (ms)`
6. **Y-axis (second):**
   - Click **+ Add layer** or **+ Add metric**
   - Function: **Formula**
   - Formula: `percentile(duration, percentile=95) / 1000000`
   - Custom label: `p95 latency (ms)`
   > Both metrics must use Formula with `/ 1000000`. Using the raw Percentile function
   > returns nanoseconds and pushes the Y-axis to 25,000,000+ making the avg line invisible.
7. **Break down by:** `resource.attributes.service.name` → Top values, size 4
8. Title: `Service Latency Over Time`
9. **Save and return**

---

### Panel 2 — Event Throughput by Sensor

**Type:** Bar chart — shows events per minute broken down by sensor ID.
**Demonstrates:** Live pipeline rate; change `SENSOR_INTERVAL_MS` in the ConfigMap and watch bar heights respond.

1. **Add panel → Create visualization**
2. Chart type: **Bar vertical stacked**
3. Data view: `traces-generic.otel-default`
4. Add KQL filter: `name: bridge-sensor-reading`
5. **X-axis:** `@timestamp` → Date histogram, **1 minute** interval
6. **Y-axis:** **Count** — custom label: `Events`
7. **Break down by:** `attributes.sensor.id` → Top values, size 10
8. Title: `Event Throughput by Sensor`
9. **Save and return**

> Filtering on `bridge-sensor-reading` means each bar represents one bridged message —
> a clean 1:1 proxy for pipeline throughput. Including all span names would triple-count
> each sensor reading (producer + bridge + consumer spans).

---

### Panel 3 — Sensor Trend Distribution

**Type:** Pie chart — shows proportion of rising/falling/stable readings.
**Demonstrates:** Redis enrichment — trend classification is added by mqtt-bridge from previous-value comparison.

1. **Add panel → Create visualization**
2. Chart type: **Pie**
3. Data view: `traces-generic.otel-default`
4. Add KQL filter: `name: bridge-sensor-reading AND attributes.sensor.trend: *`
5. **Slice by:** `attributes.sensor.trend` → Top values
6. **Metric:** `attributes.sensor.trend` → Top values
   > Kibana 8.17 pie charts require an explicit Metric field — the default does not
   > auto-populate. Add `attributes.sensor.trend` as the Metric as well as the Slice
   > to get the chart to render.
7. Title: `Sensor Trend Distribution`
8. **Save and return**

> The `attributes.sensor.trend: *` filter excludes spans where the field is absent
> (e.g., on the first reading before Redis has a previous value to compare against).

---

### Panel 4 — Error Span Rate

**Type:** Line chart — shows error span count over time per service.
**Demonstrates:** Baseline is zero for sensor services. Spikes appear during Phase 5b latency injection.

1. **Add panel → Create visualization**
2. Chart type: **Line**
3. Data view: `traces-generic.otel-default`
4. Add filter using the **structured filter form** (not raw KQL):
   - Click **Add filter**
   - Field: `status.code` / Operator: `is` / Value: `Error`
   - Click **Save**
   > Do not add a Traefik exclusion filter. Adding `is not traefik` causes "No results"
   > when no sensor service errors exist, rendering a blank panel rather than a flat zero
   > line. Traefik 401 spikes are visually distinguishable from sensor service errors
   > in the breakdown by service.
5. **X-axis:** `@timestamp` → Date histogram, **1 minute** interval
6. **Y-axis:** **Count** — custom label: `Error spans`
7. **Break down by:** `resource.attributes.service.name` → Top values, size 4
8. Title: `Error Span Rate`
9. **Save and return**

> Baseline shows a flat zero line for sensor services with occasional Traefik spikes
> from HTTP 401s (ArgoCD UI traffic). During Phase 5b latency injection, sensor service
> errors will appear as a distinct series clearly separable from the Traefik noise.
> The flat zero baseline for sensor services is the demo talking point.

---

### Panel 5 — Trace Span Timeline (Saved Search)

**Purpose:** Show the end-to-end span sequence for a single sensor reading across all three services.
**Demonstrates:** W3C traceparent propagation — one trace ID across MQTT and Kafka boundaries.

This panel uses **Discover** rather than Lens — Kibana 8 Basic does not include the APM trace waterfall view.

1. Navigate to **Analytics → Discover**
2. Data view: `traces-generic.otel-default`
3. Switch query language to **Lucene** (dropdown next to the search bar)
   > `trace_id` is a keyword field — Lucene wildcard searches work reliably; KQL does not.
4. Time range: **Last 1 hour**
5. Search:
   ```
   name:publish-sensor-reading OR name:bridge-sensor-reading OR name:consume-sensor-event
   ```
   > This filters to the three main pipeline spans only — one per service per sensor reading.
   > Excludes child spans (redis-cache-write, kafka-publish, etc.) to keep the panel readable.
6. Add columns: `resource.attributes.service.name`, `name`, `duration`, `trace_id`
7. Sort by `@timestamp` descending
8. Click **Save** → name: `Trace Span Timeline` → **Save**
9. Return to the dashboard → **Add panel → Add from library → Trace Span Timeline**

> **This panel shows the pipeline flowing live.** Do not save a specific `trace_id` filter
> into it — the trace correlation is an ad-hoc demo step performed from the dashboard,
> not a saved state. See demo sequence below.

**Demo sequence for trace correlation (performed live from the dashboard):**
1. Find any row in the panel — pick one from `sensor-producer`
2. Copy the full `trace_id` value from that row
3. Open a new Discover tab → data view: `traces-generic.otel-default` → **Lucene** mode
4. Search: `trace_id:<paste full value>` (no space after the colon)
5. Show all spans sharing that trace ID across `sensor-producer`, `mqtt-bridge`, and `event-consumer`

> This is the central story of the demo — one sensor reading, one trace ID, visible
> across two async message boundaries (MQTT and Kafka).

---

### Panel 6 — Event Consumer Logs (Saved Search)

**Purpose:** Show event-consumer log lines with structured trace context.
**Demonstrates:** Structured log-to-trace correlation — `trace_id` is now a proper field on every
log document, written by the OTel logging bridge active on all three sensor apps.

**Note on query mode:** KQL mode works for `trace_id` exact match. The `body.text` field is still
mapped as `keyword` — if you need to search body text use Lucene mode with a wildcard. For this
panel KQL is sufficient because we are filtering by service name, not body content.

1. Navigate to **Analytics → Discover**
2. Data view: `logs-generic.otel-default`
3. Query language: **KQL** (default)
4. Search:
   ```
   resource.attributes.service.name: event-consumer
   ```
5. Set time range to **Last 1 hour**
6. Add columns: `trace_id`, `span_id`, `attributes.SensorId`, `attributes.Value`, `attributes.Trend`, `body.text`
7. Sort by `@timestamp` descending
8. Click **Save** → name: `Event Consumer Logs` → **Save**
   > If you have a duplicate saved search from before the logging bridge was added,
   > delete the old one first: **Stack Management → Saved Objects** → search
   > `Event Consumer Logs` → delete, then recreate.
9. Return to dashboard → **Add panel → Add from library → Event Consumer Logs**

**Demo sequence for log-trace correlation:**
1. Find any row in the panel — copy the full `trace_id` value (32 hex characters)
2. Open a new Discover tab → data view: `traces-generic.otel-default` → KQL mode
3. Search: `trace_id: "<paste full value>"` (include the quotes)
4. Show all spans sharing that trace ID across all three services

> **Talking point:** Every log line now carries `trace_id` and `span_id` as structured
> fields — written automatically by the OTel logging bridge without any change to
> business logic. Copy a trace ID from a log line, paste it into the traces index,
> and the full end-to-end span chain appears instantly. No wildcards, no Lucene mode,
> no 8-character prefix guessing — exact structured field match.

---

### Panel 7 — Cross-Service Log Correlation (Saved Search)

**Purpose:** Show log lines from all three sensor services side by side, grouped by trace ID.
**Demonstrates:** One sensor reading produces exactly three log lines — one per service —
all carrying the same `trace_id`. This panel makes that visible at a glance.

1. Navigate to **Analytics → Discover**
2. Data view: `logs-generic.otel-default`
3. Query language: **KQL** (default)
4. Search:
   ```
   resource.attributes.service.name: sensor-producer OR resource.attributes.service.name: mqtt-bridge OR resource.attributes.service.name: event-consumer
   ```
5. Set time range to **Last 15 minutes**
6. Add columns: `resource.attributes.service.name`, `trace_id`, `attributes.SensorId`, `body.text`
7. Sort by `trace_id` ascending, then `@timestamp` ascending
   > Sorting by `trace_id` first groups the three log lines for each reading together.
   > Within each group, `@timestamp` ascending shows producer → bridge → consumer in order.
8. Click **Save** → name: `Cross-Service Log Correlation` → **Save**
9. Return to dashboard → **Add panel → Add from library → Cross-Service Log Correlation**

> **Narrower time range for this panel:** Use **Last 15 minutes** rather than Last 1 hour.
> All three sensor services produce ~3 log lines per second combined — 15 minutes is already
> ~2,700 rows. Last 1 hour would be ~10,800 rows and slow to render.

**Demo sequence:**
1. Find any `trace_id` value in the panel
2. Click the `trace_id` field value to add it as a filter
3. The panel instantly narrows to three rows — one from each service — for that single reading
4. Remove the filter to return to the live stream

> **Talking point:** Three services, two message boundaries, one trace ID. The sensor
> reading left the producer, crossed MQTT to the bridge, crossed Kafka to the consumer.
> Every hop logged the same trace ID automatically — no manual instrumentation of the
> log statements, no changes to business logic. The OTel SDK did it.

---

## Part 4 — Assemble the dashboard

1. **Analytics → Dashboards → Sensor Demo — Observability Overview**
2. Add all panels via **Add panel → Add from library**
3. Suggested layout:

```
┌─────────────────────────────────┬───────────────────────┐
│  Service Latency Over Time      │  Error Span Rate       │
│  (line, ~60% width)             │  (line, ~40% width)    │
├──────────────────┬──────────────┴───────────────────────┤
│  Event Throughput│  Sensor Trend Distribution            │
│  by Sensor (bar) │  (pie)                                │
├──────────────────┴───────────────────────────────────────┤
│  Trace Span Timeline (saved search, full width)          │
├───────────────────────────────────────────────────────────┤
│  Event Consumer Logs (saved search, half width)          │
│  Cross-Service Log Correlation (saved search, half width)│
└───────────────────────────────────────────────────────────┘
```

4. Set dashboard time range: **Last 1 hour**
5. Set auto-refresh: **30 seconds** — Edit menu → **Options** → Auto-refresh: 30s
6. Enable **Store time with dashboard**: Edit menu → **Options** → check **Store time with dashboard**
7. Click **Save** → name: `Sensor Demo — Observability Overview`

> The dashboard time range overrides individual panel time ranges. Setting to Last 1 hour
> keeps the log panels fast. Panel 7 (Cross-Service Log Correlation) uses Last 15 minutes
> internally — narrowing its saved search time range prevents it from loading thousands
> of rows when the dashboard opens.

---

## Part 5 — Export completed dashboard

Once all panels are built and arranged, export the full dashboard as NDJSON.
This snapshot can be re-imported after a PVC wipe without rebuilding from scratch.

1. **Stack Management → Saved Objects**
2. Search for: `Sensor Demo`
3. Select all matching objects (dashboard + all visualizations + saved searches)
4. Also select the two data views: `traces-generic.otel-default` and `logs-generic.otel-default`
5. Click **Export** → save as `sensor-demo-kibana-complete.ndjson`
6. Copy to `~/Projects/poc/documentation/` and commit

> Re-import procedure after PVC wipe:
> 1. Run `obs-init.sh` (creates index templates)
> 2. Run `obs-ilm-init.sh` (attaches ILM policy)
> 3. Wait ~30s for data to flow
> 4. Import `sensor-demo-kibana-complete.ndjson` via Saved Objects → Import

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Import shows version warnings | Kibana 8 upgrading 7.x format — safe | Dismiss and continue |
| 4 visualization stubs fail on import | Empty Lens state rejected by Kibana 8.17 | Expected — ignore, build panels manually |
| Data view shows 0 documents | `pf-es` not running, or time range too narrow | Confirm `pf-es` active; widen time range |
| Field missing from Lens picker | Data view field list stale | Stack Management → Data View → Refresh field list |
| `attributes.sensor.trend` missing | No `bridge-sensor-reading` spans in time range | Widen time range; check mqtt-bridge logs |
| `attributes.sensor.delta` formula fails | Field is stored as keyword string, not float | Do not use in numeric aggregation |
| Pie chart shows no data | Metric field not set | Add `attributes.sensor.trend` explicitly as both Slice and Metric |
| Error panel shows "No results" | Traefik exclusion filter active with no sensor errors | Remove `is not traefik` filter — use `status.code: Error` alone |
| Error panel Y-axis at 5000+ | Filter not applied — counting all spans | Use structured filter form, not raw KQL bar |
| Log panel search returns nothing | Wrong query language or wrong wildcard syntax | Switch to **Lucene**; use `body.text:*trace*` not `body.text:trace` |
| `trace_id` not showing on log documents | Old pods still running pre-bridge image | Check image SHAs: `kubectl get pods -n sensor-dev -o wide`; verify CI built new images |
| Panel 7 loads slowly | Time range too wide for three-service log volume | Ensure saved search is scoped to Last 15 minutes, not the dashboard override |
| Log panel very slow to load | Leading wildcard on 5M+ keyword field | Narrow dashboard time range to Last 1 hour |
| Search Sessions deprecation warning | Kibana 8.15+ cosmetic warning | Safe to ignore |
| Dashboard time range resets on reload | Store time option not enabled | Edit → Options → enable **Store time with dashboard** → Save |
| Lens formula rejected | Formula entered in wrong metric type | Confirm using **Formula** function, not Percentile or Average |

---

## Demo talking track (panel by panel)

**Setup:** Dashboard open, Last 1 hour, 30s auto-refresh.

**Panel 1 — Service Latency Over Time:**
> "Every span from every service is collected without modifying any business logic.
> We can see avg and p95 latency per service over time. mqtt-bridge includes Redis
> enrichment time. event-consumer includes Kafka consumer lag."

**Panel 2 — Event Throughput by Sensor:**
> "Three sensors, each publishing every second. We can change that interval with
> a single ConfigMap edit and watch this panel respond within 30 seconds — no
> redeployment, no code change." *(Phase 5b: do the edit live)*

**Panel 3 — Sensor Trend Distribution:**
> "The mqtt-bridge checks Redis for the previous reading and classifies each value
> as rising, falling, or stable. That enrichment shows up here. No code in the
> producer or consumer knows about this — it's added at the bridge layer."

**Panel 4 — Error Span Rate:**
> "Flat zero for the sensor pipeline right now. During the next phase we'll inject
> artificial latency and you'll see spikes appear here — correlated to the exact
> service and time window where the injection happened."

**Panel 5 — Trace Span Timeline:**
> "This panel shows the pipeline flowing live — one row per service per sensor reading.
> Pick any row, copy that trace ID, open a new search tab and paste it in.
> Every span with that same ID is part of the same physical sensor reading —
> from the producer's MQTT publish, through the bridge, onto Kafka, and into
> the consumer. One reading. One trace. Across two async message boundaries."

**Panel 6 — Event Consumer Logs:**
> "Every log line from the event-consumer now carries a structured `trace_id` field —
> written automatically by the OTel logging bridge. Copy any trace ID, switch to the
> traces index, paste it in — the full end-to-end span chain appears. No wildcards,
> no 8-character prefix guessing. Exact structured field match."

**Panel 7 — Cross-Service Log Correlation:**
> "This panel shows all three services side by side. One sensor reading — three log lines,
> one from each service, all carrying the same trace ID. Click any trace ID to filter
> and watch it collapse to exactly three rows: producer, bridge, consumer. That's the
> full journey of a single temperature reading, logged end-to-end with zero changes
> to business logic."

---

## Run order for a fresh cluster build

```bash
# Phase 2 prerequisites (must already be complete)
bash ~/Projects/poc/scripts/obs-init.sh       # index templates + credentials
bash ~/Projects/poc/scripts/obs-ilm-init.sh   # 2h ILM policy

# Wait ~30s for OTel collectors to start writing data
# Verify data is flowing — see Check 2 in Commands section below
# All four services should appear with doc_count > 0

# Then in Kibana:
# 1. Import sensor-demo-kibana.ndjson (data views + dashboard shell)
# 2. Build panels per this runbook
# 3. Export completed dashboard as sensor-demo-kibana-complete.ndjson
# 4. Commit to documentation/
```

---

## Commands

The pre-flight checks run before building any panels. Run these in order on the Linux
host. All commands use `ES_PASS` — set it once at the top of your session:

```bash
ES_PASS=$(kubectl get secret elasticsearch-es-elastic-user \
  -n observability -o jsonpath='{.data.elastic}' | base64 -d | tr -d '\r\n')
```

> `ES_PASS` is set in the current shell only. If you open a new terminal or the session
> has been idle, re-run this line before any `curl` commands.

---

### Check 1 — Observability pod status

Confirms all observability components are Running before touching Kibana.

```bash
docker run --rm --network host \
  -v ~/Projects/poc/kube:/root/.kube \
  -e KUBECONFIG=/root/.kube/config \
  devops-toolkit:latest kubectl get pods -n observability --no-headers \
  | awk '{print $1, $3}'
```

**Expected output:**
```
elasticsearch-es-default-0              Running
kibana-kb-<hash>                        Running
otel-collector-daemonset-<hash>         Running
otel-collector-daemonset-<hash>         Running
otel-collector-daemonset-<hash>         Running
otel-collector-gateway-<hash>           Running
```

---

### Check 2 — Trace counts by service

Confirms data is flowing from all services into Elasticsearch. Run this before
importing data views — if counts are zero, the pipeline needs attention first.

```bash
curl -sk -u "elastic:${ES_PASS}" \
  "https://127.0.0.1:9200/traces-*/_search" \
  -H "Content-Type: application/json" \
  -d '{
    "size": 0,
    "aggs": {
      "services": {
        "terms": {"field": "resource.attributes.service.name", "size": 10}
      }
    }
  }' \
  | jq '.aggregations.services.buckets[] | {service: .key, count: .doc_count}'
```

**Expected output** (counts increase over time):
```json
{"service": "mqtt-bridge",      "count": 39642}
{"service": "sensor-producer",  "count": 39624}
{"service": "event-consumer",   "count": 26422}
{"service": "traefik",          "count": 13291}
```

All four services must be present. If `mqtt-bridge` or `event-consumer` are missing,
check the MQTT topic mismatch pattern in the troubleshooting guide (Pattern 12).

---

### Check 3 — Kibana license tier

Confirms the Basic license is active. Lens formula layer (`average(duration) / 1000000`)
requires Basic or above.

```bash
curl -sk -u "elastic:${ES_PASS}" \
  "https://127.0.0.1:9200/_license" \
  | jq '{status: .license.status, type: .license.type}'
```

**Expected output:**
```json
{"status": "active", "type": "basic"}
```

---

### Check 4 — Sensor fields on bridge spans

Confirms `attributes.sensor.trend` and `attributes.sensor.delta` are present on
`bridge-sensor-reading` spans, and identifies the stored type of `sensor.delta`
(string keyword — cannot be used in numeric Lens aggregations).

```bash
curl -sk -u "elastic:${ES_PASS}" \
  "https://127.0.0.1:9200/traces-*/_search" \
  -H "Content-Type: application/json" \
  -d '{
    "size": 1,
    "query": {"term": {"name": "bridge-sensor-reading"}},
    "_source": [
      "name",
      "resource.attributes.service.name",
      "attributes.sensor.id",
      "attributes.sensor.value",
      "attributes.sensor.trend",
      "attributes.sensor.delta",
      "duration",
      "status.code"
    ]
  }' \
  | jq '.hits.hits[0]._source'
```

**Expected output:**
```json
{
  "name": "bridge-sensor-reading",
  "duration": 7302300,
  "attributes": {
    "sensor.id": "sensor-03",
    "sensor.value": 22.32,
    "sensor.trend": "falling",
    "sensor.delta": "-10.46"
  },
  "status": {"code": "Unset"},
  "resource": {"attributes": {"service.name": "mqtt-bridge"}}
}
```

Note: `sensor.delta` is a quoted string (`"-10.46"`), not a number. Do not use it
in numeric Lens aggregations — it will return no results or an error.

---

### Check 5 — status.code values

Confirms the exact string values stored for `status.code` so Lens filters are correct.
Also reveals whether any errors already exist in the index.

```bash
curl -sk -u "elastic:${ES_PASS}" \
  "https://127.0.0.1:9200/traces-*/_search" \
  -H "Content-Type: application/json" \
  -d '{
    "size": 0,
    "aggs": {
      "status_values": {
        "terms": {"field": "status.code", "size": 10}
      }
    }
  }' \
  | jq '.aggregations.status_values.buckets'
```

**Expected output:**
```json
[
  {"key": "Unset", "doc_count": 120551},
  {"key": "Error", "doc_count": 2}
]
```

The correct filter string for the error panel is `status.code: Error` (string match).
If `Error` has zero count, the filter is still correct — it will fire when errors occur.

---

### Check 6 — Error span identity

Identifies what the existing error spans actually are before building the error panel.
Determines whether a Traefik exclusion filter is needed.

```bash
curl -sk -u "elastic:${ES_PASS}" \
  "https://127.0.0.1:9200/traces-*/_search" \
  -H "Content-Type: application/json" \
  -d '{
    "size": 5,
    "query": {"term": {"status.code": "Error"}},
    "_source": [
      "name",
      "resource.attributes.service.name",
      "status",
      "attributes.http.response.status_code",
      "duration"
    ]
  }' \
  | jq '.hits.hits[]._source'
```

**Result from this session:**
```json
{
  "name": "ReverseProxy",
  "duration": 4304150,
  "attributes": {"http.response.status_code": 401},
  "status": {"code": "Error"},
  "resource": {"attributes": {"service.name": "traefik"}}
}
```

Both error spans were Traefik `ReverseProxy` HTTP 401s from the ArgoCD UI — not sensor
pipeline errors. Adding a Traefik exclusion filter to the error panel causes "No results"
when no sensor errors exist. Use `status.code: Error` alone and accept Traefik spikes
as background noise distinguishable by the service breakdown.

---

### Check 7 — body.text field mapping

Confirms how `body.text` is mapped in the logs index. This determines the correct
search syntax for the log correlation panel.

```bash
curl -sk -u "elastic:${ES_PASS}" \
  "https://127.0.0.1:9200/.ds-logs-generic.otel-default-$(date +%Y.%m.%d)-000004/_mapping" \
  | jq '.[] .mappings.properties.body'
```

> If the index name has rolled over, find the current backing index name first:
> ```bash
> curl -sk -u "elastic:${ES_PASS}" \
>   "https://127.0.0.1:9200/_cat/indices?h=index&s=index" \
>   | grep "logs-generic.otel-default"
> ```

**Result from this session:**
```json
{
  "properties": {
    "text": {
      "type": "keyword",
      "ignore_above": 1024
    }
  }
}
```

`body.text` is a `keyword` field — not `text`. This means:
- KQL wildcards do not work on it
- Lucene full-text search does not work on it
- Lucene wildcard syntax **does** work: `body.text:*trace*`
- Use **Lucene mode** (not KQL) in Discover for body text searches

---

### Check 8 — trace_id on log documents

Confirms the OTel logging bridge is active and `trace_id` is present as a structured
field on log documents from the sensor apps. Run after deploying the updated app images.

```bash
ES_PASS=$(kubectl get secret elasticsearch-es-elastic-user \
  -n observability -o jsonpath='{.data.elastic}' | base64 -d | tr -d '\r\n')

curl -sk -u "elastic:${ES_PASS}" \
  "https://127.0.0.1:9200/logs-generic.otel-default/_search?pretty" \
  -H "Content-Type: application/json" \
  -d '{
    "size": 1,
    "query": {
      "term": {
        "resource.attributes.service.name": "event-consumer"
      }
    },
    "_source": ["trace_id","span_id","attributes","resource.attributes.service.name","body"]
  }'
```

**Expected output** (abbreviated):
```json
{
  "trace_id": "c3d42531513aa00042f9ece03743e145",
  "span_id": "8b22dbec92158e3d",
  "attributes": {
    "TraceId": "c3d42531",
    "SensorId": "sensor-03",
    "Value": 32.45,
    "Trend": "rising"
  },
  "resource": {
    "attributes": {
      "service.name": "event-consumer"
    }
  },
  "body": {
    "text": "[trace:{TraceId}] Consumed event sensorId={SensorId} ..."
  }
}
```

`trace_id` and `span_id` present as top-level fields confirms the logging bridge is working.
Note that `body.text` contains the raw message template (with `{placeholders}`) — the
rendered parameter values are in the `attributes` block as structured fields.
