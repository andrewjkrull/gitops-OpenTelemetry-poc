# ADR-0001 — Replace ECK/Kibana/Jaeger with the Grafana LGTM stack

- **Status:** Accepted
- **Date:** 2026-04-19
- **Scope:** PoC platform (k3d on `devajk01`). AKS implications noted but out of scope for this decision.

---

## Context

The PoC platform currently runs Elasticsearch, Kibana, and Jaeger for observability.
This was the right choice for Phases 1–6: ECK is well documented, Kibana's Lens editor
got the leadership demo across the line, and Jaeger gave us a native trace waterfall.

Two things changed after Phase 6:

1. **The AKS production platform picked a different stack** — Prometheus, Grafana,
   Loki, Tempo, Thanos. The PoC and production drift from each other by a full stack.
   Every debugging habit, dashboard, and query language learned on the PoC is
   throwaway knowledge for production.

2. **The developer-visibility problem in AKS Dev/QA is urgent.** Developers today
   cannot reach their application logs in the lower AKS environments. The immediate
   need is a tested pattern for "open a web UI, filter to my service, see logs with
   trace IDs I can click through to a trace." The PoC is the lowest-risk place to
   prove that pattern before taking it to a real cluster.

Continuing with ECK/Kibana/Jaeger on the PoC trains muscle memory that does not
transfer. Switching now keeps the PoC useful as a reference implementation for
the production stack.

## Decision

Replace ECK, Elasticsearch, Kibana, and Jaeger on the PoC with the Grafana
**LGTM** stack:

- **Loki** — log aggregation
- **Grafana** — unified UI for logs, traces, and metrics
- **Tempo** — distributed tracing backend
- **Mimir** — *not adopted for the PoC.* Prometheus (via `kube-prometheus-stack`)
  handles metrics. Mimir is the horizontally-scalable Prometheus replacement and
  is unnecessary at PoC scale. Production AKS will revisit.

All three new backends use **filesystem storage** (Loki single-binary mode, Tempo
monolithic mode) for the PoC. Object storage (Azure Blob, S3, or eventually
RustFS) is a production-cluster concern.

All three backends, plus Grafana, are installed from **upstream community Helm
charts**:

- `grafana/loki`
- `grafana/tempo`
- `prometheus-community/kube-prometheus-stack` (brings Prometheus, Alertmanager,
  node-exporter, kube-state-metrics, **and Grafana**)

The OTel Collector pipeline stays. The DaemonSet and Gateway remain the single
collection path for traces, logs, and metrics from application workloads. Only
the **exporter configuration** changes:

- `elasticsearch` exporter → removed
- `otlp` exporter to Tempo (traces)
- `otlphttp` exporter to Loki's OTLP ingest endpoint (logs)
- `prometheusremotewrite` exporter to Prometheus (metrics)

Infrastructure metrics (kubelet, node-exporter, kube-state-metrics, the OTel
collector itself, Traefik, Vault) are scraped by Prometheus via **ServiceMonitors
and PodMonitors** managed by the Prometheus Operator. This is the pattern the
Prometheus Operator exists to enable, and it is the same pattern AKS will use.

## Consequences

### Positive

- **Single stack across PoC and production roadmap.** Dashboards, queries, and
  datasource configuration built on the PoC are directly reusable in AKS.
- **PromQL + LogQL + TraceQL** instead of KQL + Lens formulas + Jaeger's own UI.
  Three query languages that share a family resemblance, one UI to learn.
- **Grafana's "Explore" view natively links logs to traces** via trace ID, without
  the Kibana copy-paste dance.
- **Eliminates Kibana-specific operational quirks** documented in Phase 5a:
  nanosecond duration division, Lens pie-chart metric gotcha, re-save-to-refresh
  bug, Traefik 401 filter dead zones.
- **Removes ~4 GB of resident memory** (Elasticsearch + Kibana JVM overhead)
  from the PoC cluster. Loki + Tempo + Prometheus + Grafana together are
  lighter.
- **Upstream Helm charts only** — the same `helm install` commands work against
  any Kubernetes cluster, including AKS.

### Negative

- **Loss of the Phase 5a dashboard investment.** The seven Kibana panels are
  rebuilt, not migrated. Estimated cost: one focused session.
- **Loss of the Phase 6 Jaeger UI.** Tempo's trace waterfall in Grafana is the
  replacement; it is functionally equivalent for the "find the slow span" use
  case but the UI is different from Jaeger.
- **Three new products to learn operationally.** Loki, Tempo, and the Prometheus
  Operator each have their own failure modes and tuning knobs. Grafana replaces
  Kibana but is itself a new thing.
- **No full-text search over logs in the way Kibana provides.** LogQL is
  label-first with line filters; it is different, not worse, but the mental
  model has to shift.
- **OTLP ingest into Loki is newer than the deprecated `loki` exporter path.**
  The OTel Collector 0.123.0 supports it, Loki 3.x supports it, but the
  combination has less battle-tested runtime hours than ECK did. This is a PoC
  — acceptable risk.

### Neutral

- **Jaeger as a brand goes away.** Tempo + Grafana provides the same user
  workflow. Internal references to "Jaeger" in docs and diagrams need updating.
- **Kibana saved-object NDJSON exports become historical artifacts.** Kept in
  `documentation/archive/` for reference, not maintained.

## Alternatives considered

### Keep ECK/Kibana, add Grafana as a second pane of glass

Rejected. Doubles the operational surface area without solving the "PoC and
production diverge" problem. The Kibana dashboards would continue to be the
primary demo UI, which re-entrenches the drift.

### Migrate to Grafana + Elasticsearch as a data source

Rejected. Grafana can query Elasticsearch, but Loki and Tempo are the native
Grafana backends with the best UX. Using Elasticsearch as the log store under
Grafana preserves all of ECK's operational weight while giving up Loki's
simplicity. Worst of both worlds.

### Defer the migration until after the AKS production platform is running

Rejected. This is the current status quo and is the direct cause of the
developer log-visibility gap in AKS Dev/QA. Waiting for AKS to be fully built
before proving the pattern means developers keep flying blind in Dev/QA for
weeks. The PoC exists to de-risk production; using it that way now is the
correct move.

## Out of scope for this ADR

- AKS log-collection architecture (Alloy vs OTel Collector vs native Azure
  Monitor integration). Decided separately once the DevOps AKS cluster is
  available for experimentation.
- Long-term object storage choice for Loki/Tempo in production (Azure Blob
  vs RustFS vs S3-compatible).
- Mimir adoption. Revisited if/when Prometheus HA or long-term retention
  becomes a real requirement.
- Alerting rule migration. PoC has no production alerts to migrate; Alertmanager
  is installed by `kube-prometheus-stack` and left with default rules.

## References

- Phase 2 runbook — original ECK/Kibana install (superseded by this ADR)
- Phase 6 runbook — Jaeger install (superseded by this ADR)
- `phase-7-lgtm-migration-runbook.md` — the how
- Grafana Loki OTLP ingestion: <https://grafana.com/docs/loki/latest/send-data/otel/>
- kube-prometheus-stack chart: <https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack>
