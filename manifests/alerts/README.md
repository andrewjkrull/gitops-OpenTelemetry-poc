# Alert rules

This directory is where alert rule definitions live.

**Phase 7 wired up the plumbing, but no alert rules are deployed yet.**
The capability is proven end-to-end (Grafana's Alerting UI is reachable
and queries the kube-prometheus-stack Alertmanager), but authoring the
first real alert rules is deferred to a later phase.

---

## Why the plumbing is in place now

The Grafana configuration for unified alerting, the sidecar that loads
alert rule ConfigMaps, and the datasource wiring to Alertmanager all had
to be configured when `kube-prometheus-stack` was installed. Retrofitting
these later requires editing the Helm values and doing a `helm upgrade`,
which is a bigger lift than doing it up front.

So Phase 7 put the plumbing in place **and** established this directory
as the convention — but intentionally stopped short of writing example
rules against a stack with no real operational history. Real alerts come
when we have a real use case to alert on.

---

## The two authoring patterns

This platform supports alert rules from two sources, and Grafana's
Alerting UI displays both in a unified view.

### Pattern 1 — PrometheusRule CRDs

**Use when:** the alert queries only Prometheus data (metrics, RED stats
from Tempo metrics-generator, node/pod resource metrics).

**Where:** YAML files in this directory, applied as Kubernetes
`PrometheusRule` resources. The kube-prometheus-stack Prometheus
Operator auto-discovers and loads them into Prometheus.

**Example filename:** `sensor-producer-silent.prometheusrule.yaml`

**Characteristics:**
- YAML, fully declarative, GitOps-native
- Rules evaluated by Prometheus itself
- Alerts routed by the kube-prometheus-stack Alertmanager
- PromQL only — cannot query Loki or Tempo directly

### Pattern 2 — Grafana alert rule ConfigMaps

**Use when:** the alert queries multiple datasources (e.g., "Loki error
log spike correlated with Tempo latency spike") or uses data sources
Prometheus can't reach.

**Where:** ConfigMaps in this directory, labeled `grafana_alert: "1"`.
The Grafana sidecar picks them up automatically — no pod restart needed.

**Example filename:** `cross-datasource-error-correlation.alert.yaml`

**Characteristics:**
- Grafana-provisioned alert rules
- Rules evaluated by Grafana itself
- Can query any Grafana datasource (Prometheus, Loki, Tempo, mixed)
- Alerts flow to the same Alertmanager as Pattern 1 (unified routing)

---

## Where alerts flow to

Both patterns deliver to the **kube-prometheus-stack Alertmanager**
running in the `observability` namespace. This means:

- Silences created in Grafana UI apply to alerts from both patterns.
- Mute timings, notification policies, and contact points are configured
  once (in the Alertmanager) and apply to everything.
- Grafana's Alerting UI shows rule state, firing history, and silences
  from both sources in one pane.

The Alertmanager itself is not ingressed — it's accessed only through
Grafana's proxy, following the same "only Grafana is exposed to the
outside" principle as Prometheus, Loki, and Tempo.

---

## Next steps (future phase)

When the first real alerts are written, this README should be expanded
into a full authoring guide with:

- A working PrometheusRule example committed here as a template
- A working Grafana ConfigMap example committed here as a template
- Notification policy and contact point setup (Slack? email? webhook?)
- Test procedures for verifying a new alert fires correctly
- Naming conventions for alert rule files and alert names

Until then, the canonical references are:

- Prometheus Operator PrometheusRule CRD:
  https://prometheus-operator.dev/docs/operator/api/#monitoring.coreos.com/v1.PrometheusRule
- Grafana alert rule provisioning:
  https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/
