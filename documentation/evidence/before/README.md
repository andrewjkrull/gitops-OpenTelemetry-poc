# Logging evidence — before

This directory is a point-in-time capture of the logging pipeline state.
It exists to support before/after comparison when changes are made to
app logging, the OTel collector, or Loki.

## What's in here

| File | Purpose |
|------|---------|
| `sensor-producer-raw.json` | Raw Loki API response for the sensor-producer stream |
| `mqtt-bridge-raw.json`     | Raw Loki API response for the mqtt-bridge stream |
| `event-consumer-raw.json`  | Raw Loki API response for the event-consumer stream |
| `queries.md`               | Exact LogQL queries and API calls used |
| `versions.md`              | Helm chart versions, container images, OTel package versions, git SHA |
| `README.md`                | This file |

Screenshots (PNG) from the Grafana Explore view at the same time window
should be added to this directory by hand — the script cannot capture them.

## When this was captured

**Timestamp:** 2026-04-22T17:24:21Z
**Query window:** 2026-04-22T17:22:21Z → 2026-04-22T17:24:21Z (2 minutes)
**Mode:** before

## How to reproduce

```bash
# In one terminal — port-forward Loki
pf-loki

# In another terminal — run the capture script
bash scripts/capture-logging-evidence.sh --mode before --minutes 2
```

## How to diff before vs after

Once both `before/` and `after/` directories exist:

```bash
# Coarse: which fields changed, which went away, which appeared
diff <(jq -S '[.data.result[].values[][1] | fromjson? // .] | .[0]' documentation/evidence/before/sensor-producer-raw.json) \
     <(jq -S '[.data.result[].values[][1] | fromjson? // .] | .[0]' documentation/evidence/after/sensor-producer-raw.json)

# Line-level: body text changes
diff <(jq -r '.data.result[].values[][1]' documentation/evidence/before/sensor-producer-raw.json | head -20) \
     <(jq -r '.data.result[].values[][1]' documentation/evidence/after/sensor-producer-raw.json | head -20)
```

## Provenance note

Raw JSON files are the authoritative evidence. Screenshots are illustrative.
If the two disagree, trust the JSON — it's what the system actually emitted.
