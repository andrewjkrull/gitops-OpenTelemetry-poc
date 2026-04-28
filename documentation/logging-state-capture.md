# Logging State Capture — Findings & Scope Recommendation

**Status:** Findings confirmed by captured evidence
**Context:** Phase 7 handoff Item 1 (app logging cleanup)
**Scope:** `sensor-producer`, `mqtt-bridge`, `event-consumer` on the LGTM stack
**Evidence:** `documentation/evidence/before/` — 342 raw Loki records captured 2026-04-22T17:22–17:24Z
**Date:** 2026-04-22

## Purpose of this document

The Phase 7 handoff diagnosed the logging issue as "unrendered template
placeholders — variables not being supplied as arguments." That diagnosis
was partially correct but materially incomplete. This document walks
through the hypothesis, the evidence gathered to test it, and the
confirmed findings — including one that was not predicted and that
reshapes the fix.

It also serves as a working example of the evidence-first discipline that
should apply to every architectural claim about this platform: form a
hypothesis, capture structured data that can confirm or refute it, then
decide scope on what the evidence actually shows rather than on what the
first symptom suggested.

## TL;DR

Three problems, all confirmed by evidence:

1. **Log record bodies are unrendered message templates** — every record
   in the capture contains literal `{TraceId}`, `{SensorId}`, `{Value}`,
   etc. rather than substituted values. 342 of 342 records affected.

2. **High-cardinality values are being promoted to Loki *stream labels***,
   not structured metadata. Every log record produces its own unique
   Loki stream. Over a 2-minute capture, 342 records produced 342
   distinct streams. This is the Loki cardinality anti-pattern made
   material.

3. **The `[trace:{TraceId}]` prefix is redundant** with OTel's native
   `trace_id` attribute.

One additional finding the original Phase 7 diagnosis could not have
predicted:

4. **Problem 2 is not entirely an application-layer problem.** OTel's
   own `trace_id`, `span_id`, and `observed_timestamp` are being promoted
   to Loki stream labels by default during OTLP ingestion. This is a
   platform-layer concern (Loki `/otlp` endpoint behavior), not a .NET
   code concern. Fixing the apps cleans up half the damage; the other
   half requires configuration in the collector or in Loki.

**Recommended scope:** Framework-aligned restructure of the three apps
*plus* OTLP label-promotion discipline at the collector/Loki layer,
captured together as a single ADR with before/after evidence. This is
the smallest scope that actually solves the problem and it produces
the reference implementation artifact that transfers to AKS, the OTel
TestPack, and The Scaffold Rack.

## Original diagnosis vs. what the evidence shows

The Phase 7 handoff said:

> `{TraceId}`, `{SensorId}`, etc. are literal strings, not interpolated
> values. This is a bug in the .NET message templates — the variables
> referenced in the format string are not being supplied as arguments.

This framing predicted a .NET bug fixable by editing `Program.cs` in
each of the three apps. Code inspection before any capture showed this
framing was wrong:

```csharp
// sensor-producer/Program.cs, line 253
_log.LogInformation(
    "[trace:{TraceId}] Published sensorId={SensorId} value={Value} interval={IntervalMs}ms",
    activity?.TraceId.ToString()[..8] ?? "none",
    sensorId, value, _intervalMs);
```

Four placeholders, four arguments, in order. The same pattern holds in
`mqtt-bridge/Program.cs` (line 359) and `event-consumer/Program.cs`
(line 260). Every hot-path log in all three apps passes its named
properties correctly. If the handoff's diagnosis were correct, the
rendered Body would contain the values.

The evidence shows something different. That gap is where this
investigation started.

## Evidence captured

342 raw Loki records were captured via `scripts/capture-logging-evidence.sh`
on 2026-04-22T17:24Z — 114 records per service over a 2-minute window
(1 record/second, which matches the configured `SENSOR_INTERVAL_MS=1000`).

See `documentation/evidence/before/` for:

- `sensor-producer-raw.json` — raw Loki API response
- `mqtt-bridge-raw.json`
- `event-consumer-raw.json`
- `versions.md` — chart versions, image SHAs, OTel package versions
- `queries.md` — exact LogQL queries used
- `loki-logs-before.png`, `loki-logs-detail-before.png` — visual reference

All measurements below derive from these files.

## Finding 1 — Bodies contain unrendered templates

The Body field of every captured log record contains the literal
message template, unsubstituted:

```
[trace:{TraceId}] Published sensorId={SensorId} value={Value} interval={IntervalMs}ms
[trace:{TraceId}] Bridged sensorId={SensorId} value={Value} trend={Trend}
[trace:{TraceId}] Consumed event sensorId={SensorId} value={Value}{Unit} trend={Trend} delta={Delta}
```

All 342 of 342 records in the capture show this pattern. The bodies
are byte-for-byte identical within each service — only three unique
body strings exist across the entire capture.

### Why

This is defined behavior of the OTel Logs Bridge for
`Microsoft.Extensions.Logging` in the 1.9.x line. The bridge emits
each log record with:

- **Body** = the unrendered message template
- **Attributes** = named properties with their substituted values

It is not a .NET bug. It is the contract between `ILogger` and the
OTLP exporter as implemented in this package version. Serilog with
the OpenTelemetry sink behaves differently — it renders the Body and
stores the template separately as `message_template`. The PoC uses
stock MEL, not Serilog, so we get the MEL behavior.

### Impact

Glance-ability is destroyed. An operator reading a log stream in
Grafana sees `{SensorId}` where they expect `sensor-02`. The data is
not lost — it is in the attributes, queryable via LogQL filters like
`| SensorId="sensor-02"` — but the human-readable line conveys
nothing. Existing dashboard panels work because they were written
against the structured attributes; ad-hoc investigation suffers.

## Finding 2 — Values are promoted to Loki stream labels

This is the finding that reframes the fix. Every record in the
capture creates its own unique Loki stream because high-cardinality
values are being emitted as stream labels rather than as structured
metadata.

### Measurement

Stream count equals record count, per service:

| Service | Records captured | Distinct streams |
|---------|------------------|------------------|
| sensor-producer | 114 | 114 |
| mqtt-bridge | 114 | 114 |
| event-consumer | 114 | 114 |

Each log record = one new stream. This is as close to a pathological
cardinality case as one can construct.

### Which labels are causing it

21 label keys are attached to every stream. Of those, several have
cardinality equal to or near the record count:

| Label | sensor-producer | mqtt-bridge | event-consumer | Source |
|-------|-----------------|-------------|----------------|--------|
| `TraceId` | 114 | 114 | 114 | App (custom) |
| `Value` | 113 | 113 | 113 | App (custom) |
| `Delta` | — | — | 111 | App (custom) |
| `observed_timestamp` | 114 | 114 | 114 | OTel SDK |
| `span_id` | 114 | 114 | 114 | OTel SDK |
| `trace_id` | 114 | 114 | 114 | OTel SDK |

Low-cardinality labels, by contrast, are the ones that *should* be
labels under any sensible Loki scheme:

| Label | Distinct values | Appropriate as label? |
|-------|-----------------|-----------------------|
| `service_name` | 1 per service | Yes |
| `service_namespace` | 1 | Yes |
| `deployment_environment` | 1 | Yes |
| `severity_text` | 1 (`Information`) | Yes |
| `severity_number` | 1 (`9`) | Yes |
| `scope_name` | 1 per service | Yes |
| `service_version` | 1 | Yes |

### Two distinct sources, two distinct problems

The high-cardinality labels come from two different places, and
recognizing this changes the fix:

**App-origin labels** (`TraceId`, `SensorId`, `Value`, `Delta`,
`IntervalMs`, `Trend`) are named properties in the .NET
`ILogger` calls. Loki's OTLP ingestion promotes every OTLP log
record attribute to a stream label unless told otherwise. Fixing
the apps — either by removing these fields from the template entirely
and logging them via `BeginScope`/attribute-only, or by splitting
them into structured event shapes per the archetype model — addresses
this half.

**OTel-origin labels** (`trace_id`, `span_id`, `observed_timestamp`,
`service_instance_id`, `scope_name`, `severity_text`, etc.) are
attributes attached by the OTel SDK itself and cannot be removed at
the app layer without breaking distributed tracing correlation. They
must be kept as attributes but demoted from labels to structured
metadata fields at the OTLP-ingest boundary. This is a Loki
configuration concern or a collector `transform` processor concern —
not a .NET concern.

### Impact

Loki's performance and storage model both assume low-label-cardinality.
Streams are the indexing unit. A system emitting one stream per
record is effectively using Loki as a single-row-per-stream database,
which is the opposite of what Loki is designed for. At PoC scale
(~100 records/sec across 3 services) this is uncomfortable but not
fatal. At platform scale (dozens of services, thousands of records/sec)
this pattern would produce operational problems: slow queries, high
memory pressure on Loki ingesters, and eventually stream-limit
rejections.

The framework doc attached to this investigation explicitly named this
risk: *"High-cardinality labels destroy Loki."* The evidence confirms
we are already doing it — at PoC scale — and the pattern would propagate
to every future .NET service under the current conventions.

## Finding 3 — `[trace:{TraceId}]` prefix is redundant

The app-level code prepends `[trace:{TraceId}]` to each log template,
using a truncated 8-character slice of `activity?.TraceId`:

```csharp
activity?.TraceId.ToString()[..8] ?? "none"
```

Meanwhile, the OTel SDK automatically attaches the full 32-character
`trace_id` as an attribute on every log record. In the evidence:

- `TraceId` (app-injected, 8 chars): `01382025`
- `trace_id` (OTel-injected, 32 chars): `013820255c03b4bd3b43daa50aab38a1`

The app's `TraceId` is literally a left-substring of OTel's `trace_id`.
Removing the prefix loses nothing — the full trace id remains in
`trace_id`, available for log-to-trace correlation at full precision.

There is a comment at `event-consumer/Program.cs` lines 255–259 that
explicitly documents the OTel SDK's behavior and notes that the prefix
is "without relying on the [trace:xxxxxxxx] body text prefix." The
author knew. The cleanup just never happened.

## Finding 4 — The OTLP-to-Loki ingestion path needs platform-level discipline

This was not predicted by the Phase 7 handoff and is the most
significant new finding. Loki's native `/otlp` endpoint (used by the
collector config at `manifests/otel-collector-gateway-config.yaml`
lines 39–43) maps OTLP log record attributes to Loki stream labels
by default. This is Loki 3.x's documented behavior.

Without explicit configuration, this means any OTLP log attribute
becomes an indexed stream label — which is the cause of Finding 2 in
aggregate.

Two mechanisms can fix this at the platform layer:

1. **Loki `limits_config.otlp_config`** — set
   `resource_attributes.attributes_config` and `log_attributes` to
   explicitly list which attributes may become labels. Everything
   else becomes structured metadata, which is what we want.

2. **Collector `transform` processor** — rewrite/demote attributes
   before they reach Loki, either by moving unwanted attributes off
   the log record or by marking them as non-label via the
   `loki.attribute.labels` hint.

Either approach keeps the fix off the .NET apps and makes it a
platform contract. That is the right architectural boundary:
cardinality policy belongs to the observability platform, not the
services.

## What this reframes

The original handoff scoped this as "clean up some ugly logs in three
apps." The evidence shows it is actually two coupled problems:

1. Application log call patterns that do not conform to an event-
   archetype standard (a code concern)
2. A platform-level OTLP-ingest policy that lets every attribute
   become a label (a collector/Loki config concern)

Fixing only #1 leaves the second half of the damage in place and
teaches future service owners the wrong pattern. Fixing only #2 makes
the bodies queryable-but-still-unrendered. They belong together.

## Scope recommendation

### Recommended: Scope B+ — framework-aligned apps + platform-level label policy

Work items:

**Application layer (all three apps):**

- Remove the `[trace:{TraceId}]` prefix from all log templates.
  The full `trace_id` survives as an OTel attribute.
- Restructure the hot-path logs to fit the external-call archetype
  from the framework doc, with consistent field names across services:
  `target.system`, `target.operation`, `outcome`, `duration_ms`,
  `sensor.id`, `sensor.value`, `sensor.trend`.
- Keep log templates short and verb-phrased — the Body should convey
  what happened, not carry data. Data goes in attributes.

**Platform layer (OTel collector or Loki):**

- Add explicit label-allowlist configuration so only intentional
  low-cardinality attributes become Loki stream labels. Candidate
  allowlist: `service_name`, `service_namespace`, `deployment_environment`,
  `severity_text`. Everything else flows through as structured metadata.
- Decide whether this lives in the collector (`transform` processor)
  or Loki (`limits_config.otlp_config`). Leaning collector — it's
  the enforcement boundary for the whole pipeline and it keeps Loki
  config minimal.

**Documentation layer:**

- Write an ADR capturing the logging contract: event archetypes,
  mandatory fields, label allowlist, rendering discipline. This is
  the portable artifact that transfers to AKS, OTel TestPack, and
  The Scaffold Rack.
- Update the Grafana dashboard JSON if any renamed fields break
  existing queries (`SensorId` → `sensor.id`, etc.). Same commit
  as the app changes.

**Evidence layer:**

- Re-run `capture-logging-evidence.sh --mode after` and commit the
  `after/` directory alongside `before/`. The ADR cites both.
- Compare stream counts, body rendering, and label cardinality
  before/after. Specific measurable success criteria:
  - Stream count drops from ~1-per-record to ~1-per-service-per-env
  - Body contains rendered human-readable text, not templates
  - No label has cardinality > 10 across the capture

### Alternative scopes and why they were rejected

**Scope A — minimal fix (delete prefix, ship).** Rejected. This
addresses Finding 3 only and leaves Findings 1, 2, and 4 in place.
The effort is pure throwaway because the code will be rewritten again
when Findings 1 and 2 are addressed properly.

**Scope B as originally proposed — app-layer restructure only.**
Rejected in light of Finding 4. Cleaning up the .NET apps without
also constraining OTLP-to-Loki label promotion leaves the framework
for future services in place: any new service that emits an OTLP
attribute gets it promoted to a label. The lesson does not transfer.

**Scope C — investigate first, then decide.** Superseded by the
evidence captured here. We investigated. We decided.

## What this document demonstrates as a discipline

This investigation followed a specific pattern that the platform team
should adopt as standard practice for any observability or performance
claim:

1. **State the hypothesis plainly.** The Phase 7 handoff had one;
   it was partially right and partially wrong, and that was only
   discoverable by testing it.
2. **Inspect the code before accepting the hypothesis.** A fifteen-
   minute read of `Program.cs` in all three apps showed the handoff's
   specific claim ("variables not supplied as arguments") was
   inconsistent with the source. That alone reframed the problem.
3. **Capture raw, structured evidence.** Screenshots are for humans.
   Raw JSON is for engineers. Both belong in the evidence directory,
   but only the JSON is authoritative.
4. **Count things.** 114 streams per service is a number. "The
   logs look bad" is not. Numbers turn disagreements about
   interpretation into agreements about measurement.
5. **Let the evidence produce findings the hypothesis did not
   predict.** Finding 4 was not in the Phase 7 handoff and would
   not have surfaced from a code-only analysis. It surfaced because
   the JSON schema made it visible.
6. **Update the scope on what the evidence shows,** not on what
   was originally proposed.

This doc itself is the artifact of that discipline. It is the kind
of document that belongs in The Scaffold Rack as a worked example
of how platform-engineered observability investigations should go.

## Open decisions

1. **Serilog or stay on MEL?** The framework doc's `message_template`
   recommendation is Serilog-native. MEL + OTel bridge is what the
   PoC has. The `message_template` field would be useful for grouping
   by event type in LogQL — but it is a non-trivial dependency swap
   in three apps. Defer to ADR; not a blocker for the work above.

2. **Collector `transform` processor vs. Loki `limits_config.otlp_config`?**
   Both would work for Finding 4. Instinct: do it in the collector,
   because the collector is already the policy-enforcement seam.

3. **Is this Phase 8?** Calling this "Item 1" in the Phase 7 handoff
   undersells it. If we commit to Scope B+, the work deserves a phase
   marker — it produces an ADR, changes the platform contract, and
   closes a material cardinality risk. Recommendation: open Phase 8
   as "Logging contract v1."

4. **Does this ADR live in this repo or in the Scaffold Rack org?**
   Probably both — a shorter, more portable version in Scaffold Rack
   as a platform contract, with a longer implementation-detailed
   version here. The CONTEXT.md conventions from the Scaffold Rack
   work apply.

## Appendix — reproduction

Every measurement in this document can be reproduced from the
evidence files:

```bash
# Stream count per service
for f in documentation/evidence/before/*-raw.json; do
  echo -n "$(basename ${f%-raw.json}): "
  jq '.data.result | length' "$f"
done

# Cardinality of a specific label
jq '[.data.result[].stream.trace_id] | unique | length' \
  documentation/evidence/before/sensor-producer-raw.json

# Sample Body values (to confirm templates are unrendered)
jq -r '.data.result[0:3] | .[] | .values[0][1]' \
  documentation/evidence/before/sensor-producer-raw.json

# Full label key list on any record
jq -r '.data.result[0].stream | keys[]' \
  documentation/evidence/before/sensor-producer-raw.json
```
