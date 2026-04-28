# Handoff — Phase 2 LGTM-native Rewrite

**Status:** Ready to start. Scope decided, prior work documented, validation discipline established.
**Predecessor work:** Phase 7 (LGTM migration, committed at `ee984aa`)
**Originating chat:** Container log collection investigation that surfaced the Phase 2 runbook gap as a blocker.
**Parent project:** `gitops-OpenTelemetry-poc` on `devajk01`

---

## Summary

This chat resolves Item 2 from `phase-7-handoff.md` — the
`rebuild-runbook.md` Phase 2 rewrite — and integrates a new finding
that emerged after Phase 7 closed: container log collection in the PoC
has been silently broken for 22+ days because the OTel Collector
DaemonSet's filelog receiver cannot parse containerd's log format.

The originating chat was scoped to "deploy Fluent Bit to fix container
log collection." That work is real and necessary. But during planning
it became clear that landing Fluent Bit in the existing runbook is
incoherent — the runbook's Phase 2 still describes the ECK stack
(Elasticsearch, Kibana, Jaeger) that Phase 7 replaced with LGTM. Adding
a Fluent Bit step to a Phase 2 that hasn't itself been updated would
produce a runbook half-correct in two different ways.

The deliberate choice was made to use this chat as the trigger for
the full Phase 2 rewrite — Path B from the predecessor chat's
analysis. The Fluent Bit deployment becomes one component of the new
Phase 2, alongside Loki, Tempo, Grafana, and kube-prometheus-stack.

A working `rebuild-runbook.md` whose Phase 2 produces the current
LGTM-native PoC state — including container log collection — is the
deliverable. This is foundational: every future build of this stack
or any derivative (AKS platform work, The Scaffold Rack) starts from
this runbook.

---

## Context — what state we're starting from

### What's working on the live cluster

The live `devajk01` cluster is in the post-Phase-7 LGTM state. Loki,
Tempo, Grafana, and kube-prometheus-stack are all running. The three
sensor apps emit OTLP traces, metrics, and logs through the gateway
collector. Trace correlation works. The seven-panel sensor dashboard
renders. Retention policies are configured.

This is **not** the state the runbook produces. The runbook produces
the ECK state. The cluster state and the runbook state have been
divergent since Phase 7 was committed.

### What's broken on the live cluster

Container log collection. The `otel-collector-daemonset` was deployed
during the ECK era, was carried through the LGTM migration without
re-testing, and has been emitting parser errors for 22+ days while
collecting zero usable records. Loki contains only OTLP-emitted logs
from the three sensor apps:

```bash
$ curl -sG http://127.0.0.1:3100/loki/api/v1/labels | jq
{
  "status": "success",
  "data": ["deployment_environment", "service_instance_id",
           "service_name", "service_namespace"]
}
```

No `k8s_*`, no `container_*`, no namespace, no labels of any kind that
would indicate a log was scraped from pod stdout. The cluster has
been running with the *appearance* of complete observability while
container logs from every Kubernetes component, every observability-
stack service, and any future non-OTel-instrumented workload have
been completely absent.

### Why this matters for the runbook rewrite

The runbook rewrite has to install a Phase 2 stack that:

- Matches the current LGTM-native live cluster state
- Includes container log collection from the start (not as a
  bolt-on)
- Does **not** reproduce the broken DaemonSet
- Pins every chart version explicitly per the Phase 7 discipline
- Captures the LGTM-specific gotchas Phase 7 fought through, so a
  cold rebuilder doesn't have to rediscover them

It also has to be tested by a real cold rebuild, not just by reading.

---

## Scope — what this chat delivers

The deliverable is a `rebuild-runbook.md` whose Phase 2 produces the
current live cluster state plus working container log collection,
validated by a cold rebuild on a fresh cluster.

The work decomposes into seven concrete pieces.

### 1. Rewrite Phase 2 to LGTM-native

Replace the existing Phase 2 (Elasticsearch + Kibana + Jaeger) with
the LGTM stack:

- kube-prometheus-stack (Prometheus, Alertmanager, node-exporter,
  kube-state-metrics, the operator)
- Loki (single-binary mode, monolithic deployment per current
  `loki-values.yaml`)
- Tempo (single-binary, per current `tempo-values.yaml`)
- Grafana (with Vault-backed admin secret per Phase 7 pattern)
- OTel Collector gateway (current `otel-collector-gateway*.yaml`)
- **Fluent Bit** (new — see piece 2)

Section structure should follow the existing Phase 2's pattern: each
component gets a numbered step, each step has a Helm install command,
a values file path, and a wait/verify check.

### 2. Add Fluent Bit deployment as part of Phase 2

Fluent Bit replaces the broken `otel-collector-daemonset` and is
installed as part of Phase 2, not as a separate phase or addendum.

Configuration requirements:

- Install via the official `fluent/fluent-bit` Helm chart, version
  pinned
- Values file at `manifests/fluent-bit-values.yaml`, paralleling the
  existing `loki-values.yaml`, `grafana-values.yaml`, etc.
- Tail container logs from every node (path appropriate for
  k3d/containerd)
- Enrich records with Kubernetes metadata via the kubernetes filter
  (namespace, pod, container, labels, annotations)
- Output OTLP/HTTP to the gateway OTel Collector — **not** directly
  to Loki — so the gateway remains the single policy enforcement seam
- Verify post-install that Loki receives records with sensible labels
  (`k8s_namespace_name`, `k8s_pod_name`, `k8s_container_name`,
  `service_name`, `deployment_environment` at minimum)

### 3. Pin every chart version, runbook-wide

Phase 7 established this discipline for the LGTM charts. It needs to
extend to every Helm install in the runbook, not just the new ones:

- Vault
- cert-manager
- Traefik
- Gitea
- ArgoCD
- Reloader
- kube-prometheus-stack (Phase 2)
- Loki (Phase 2)
- Tempo (Phase 2)
- Grafana (Phase 2)
- Fluent Bit (Phase 2 — new)

The verified versions for the LGTM components are in `CONTEXT.md`'s
Versions table. Versions for Vault, cert-manager, Traefik, Gitea,
ArgoCD, Reloader need to be captured at runbook rewrite time from
the live cluster state.

### 4. Absorb LGTM-specific corrections from the Phase 7 migration runbook

`history/phase-7-lgtm-migration-runbook.md` contains the corrections
Phase 7 fought through in real time. These need to land in the new
Phase 2 so a cold rebuilder gets them right the first time:

- **Tempo overrides processors block** — the specific YAML structure
  that has to be present for service-graph metrics
- **Grafana derived field `matcherType: label`** — the gotcha that
  log-to-trace correlation requires this specific matcher type, not
  the default
- **LogQL structured metadata patterns** — the right way to query
  attributes that came in as structured metadata vs. labels
- **Retention policies** — the exact configuration that enforces
  Loki and Tempo retention, including the `retention_enabled: true`
  flag that defaults to false

Each of these should live in the section where it's relevant. The
derived field gotcha lives in the Grafana datasource step. The
retention policies live in the Loki and Tempo steps. The LogQL
structured metadata patterns probably belong as a reference subsection
either in Phase 2 or in Phase 5a (dashboard-building), depending on
where dashboards land in the new structure.

### 5. Delete legacy ECK manifests

The following files become unreferenced after the rewrite and must
be `git rm`d in the same commit as the runbook update:

```
manifests/elasticsearch.yaml
manifests/kibana.yaml
manifests/kibana-cert.yaml
manifests/kibana-ingressroute.yaml
manifests/kibana-transport.yaml
manifests/jaeger-cert.yaml
manifests/jaeger-ingressroute.yaml
manifests/jaeger-values.yaml
manifests/otel-gateway.yaml
manifests/otel-gateway-config.yaml
manifests/otel-gateway-config-phase6.yaml
manifests/otel-daemonset.yaml
manifests/otel-daemonset-config.yaml
```

The new gateway names are `manifests/otel-collector-gateway*.yaml` —
those stay. Only the `otel-gateway*.yaml` (without `-collector-`) and
the `otel-daemonset*.yaml` files go.

Stale Kibana dashboard exports also go:

```
documentation/sensor-demo-kibana.ndjson
documentation/sensor-demo-kibana-complete.ndjson
```

Note: `history/` files do **not** get deleted. The `history/` directory
is the project-evolution archive and serves a different purpose —
preserving artifacts that were superseded but have reference value.
`phase-7-lgtm-migration-runbook.md` and similar belong there
permanently.

### 6. Add a "How to upgrade a chart" reference section

A short section explaining the discipline:

- Check the chart's CHANGELOG before any upgrade
- Bump the `--version` pin in the runbook
- Update the values file if the chart's schema changed
- Test against a non-production cluster
- Commit the runbook, values file, and `CONTEXT.md` together — never
  separately

This section is small but load-bearing. It's how the runbook stays
maintainable after this chat closes.

### 7. Validate by cold rebuild

The Phase 7 discipline: **runbooks are tested against real clusters.**
A rewritten Phase 2 that has not been validated by execution is
hypothesis, not record.

Validation method: take a fresh cluster (k3d cluster delete + recreate
on `devajk01`, or equivalent) and run through the rewritten runbook
end-to-end. Discover issues during execution, update the runbook,
re-test until a clean run produces the expected end state.

The expected end state is:

- All Phase 2 components running and healthy
- OTLP traces, metrics, and logs flowing from sensor apps to the
  appropriate backends
- Container logs from observability-stack components reaching Loki
  with `k8s_*` labels
- The seven-panel sensor dashboard rendering with real data
- Trace-to-log correlation working from Tempo into Loki

A "before validation" snapshot of the live cluster's expected state
should be captured for comparison — what manifests are present, what
helm releases are installed, what Loki labels exist, etc. The
post-cold-rebuild state should match.

---

## Decisions already made — do not relitigate

These were worked through in the predecessor chat. The reasoning is
documented above and in `documentation/logging-state-capture.md`.
Reopening any of them should require new evidence, not new opinions.

| Decision | Choice | Reasoning |
|----------|--------|-----------|
| Container log collection: replace, not remove | Replace | Container logs are a core observability capability, not a nice-to-have |
| Tool: Fluent Bit, not Alloy or fixed OTel filelog | Fluent Bit | Operational maturity, vendor neutrality, OTLP output keeps gateway as policy seam |
| Architecture: Fluent Bit → gateway collector → Loki | Through gateway | Preserves the gateway as the single policy/normalization point |
| Naming convention for emitted attributes | OTel semantic conventions where Fluent Bit supports them | Aligns with logging-cleanup work that will follow |
| Where Fluent Bit fits in the runbook | Phase 2 (observability stack install) | Foundational; should never be a post-deployment add-on |
| Runbook scope: full Phase 2 LGTM rewrite | Path B (chosen) | Adding Fluent Bit to a Phase 2 that's still ECK-described would produce a runbook half-correct in two ways |
| Chart version pinning: discipline applies runbook-wide | All Phase 2 + earlier phases | Phase 7 discipline cannot be partial |
| Validation: cold rebuild required | Required, not optional | "Runbooks are tested against real clusters" is the established discipline |

---

## Out of scope (deferred to other chats)

The following are explicitly **not** part of this chat. They were
discussed in the predecessor chat and parked deliberately:

- **Application logging cleanup work** — `[trace:{TraceId}]` removal,
  semantic-convention dotted attribute names, archetype-based event
  structure. See `documentation/logging-state-capture.md` for the
  full analysis. This is a separate chat that pairs with the
  collector/Loki cardinality fix below.
- **Loki `limits_config.otlp_config` for stream-label allowlist** —
  the OTLP-side cardinality fix that addresses Finding 4 from the
  state-capture doc. Belongs with the application logging cleanup,
  not this chat. Note: if cardinality issues appear during cold
  rebuild validation that block Phase 2 from working, address them
  minimally to get validation passing, but defer the full discipline
  work.
- **Metrics-side cardinality limits** — `series_limit`, `label_limit`
  on Prometheus scrape configs. Deferred until the application logging
  cleanup chat where the discipline is being applied.
- **Defining application logging standards** — the framework doc
  archetypes, field naming conventions, ADR for the platform contract.
  Deferred.
- **The platform-readiness checklist series** — discussed but
  explicitly parked in the predecessor chat as a forward-looking idea.

---

## Artifacts the next chat will need

Pull these into context as the first step. Several are large; reading
them in order matters.

1. **This handoff document.**
2. **Current `rebuild-runbook.md`** — the document being rewritten.
   Read in full to understand existing Phase 1 (which is mostly fine
   and stays), Phase 2 (being replaced), Phase 4 (GitOps, references
   Phase 2 outputs), Phase 5a (Kibana dashboards — being removed/
   replaced with Grafana), and Phase 5b (Reloader — stays).
3. **`history/phase-7-lgtm-migration-runbook.md`** — the authoritative
   source for the LGTM-specific corrections that need to be absorbed
   into the new Phase 2. This is the single most important artifact.
4. **`documentation/logging-state-capture.md`** — full context on
   what was discovered about the observability pipeline, including
   the four findings and the framework doc references. Relevant
   especially for understanding why the new Phase 2 should not
   reproduce certain default behaviors.
5. **Current `CONTEXT.md`** — Versions table is the source of truth
   for chart version pins.
6. **Current LGTM manifests** (these stay, the runbook needs to
   install them correctly):
   - `manifests/kube-prometheus-stack-values.yaml`
   - `manifests/loki-values.yaml`
   - `manifests/tempo-values.yaml`
   - `manifests/grafana-datasources.yaml`
   - `manifests/grafana-ingress.yaml`
   - `manifests/grafana-dashboard-sensor-demo.yaml`
   - `manifests/otel-collector-gateway.yaml`
   - `manifests/otel-collector-gateway-config.yaml`
   - `manifests/otel-collector-gateway-service.yaml`
   - `manifests/otel-collector-gateway-podmonitor.yaml`
7. **Legacy manifests being deleted** (read once to confirm scope,
   then `git rm`):
   - `manifests/elasticsearch.yaml`
   - `manifests/kibana.yaml`, `manifests/kibana-cert.yaml`,
     `manifests/kibana-ingressroute.yaml`, `manifests/kibana-transport.yaml`
   - `manifests/jaeger-cert.yaml`, `manifests/jaeger-ingressroute.yaml`,
     `manifests/jaeger-values.yaml`
   - `manifests/otel-gateway.yaml`, `manifests/otel-gateway-config.yaml`,
     `manifests/otel-gateway-config-phase6.yaml`
   - `manifests/otel-daemonset.yaml`, `manifests/otel-daemonset-config.yaml`
   - `documentation/sensor-demo-kibana.ndjson`,
     `documentation/sensor-demo-kibana-complete.ndjson`
8. **A current `kubectl get all -A`** plus
   `helm list -A --output=json` to confirm live cluster state matches
   the manifests' description and to capture exact installed versions.

---

## What was learned in the predecessor chat — carry these forward

These principles emerged from the work and apply to this and future
observability work. They are not specific to this chat's deliverable
but should inform every decision in it.

- **Defaults in observability tooling are often quietly wrong.** Loki's
  OTLP ingestion promotes attributes to labels by default. The OTel
  filelog receiver fails to parse containerd logs without specific
  configuration. Tools assume conventions but don't enforce them.
  Every default needs to be verified against the specific pipeline,
  not trusted because it shipped that way.

- **Cardinality is a platform contract, not a per-service afterthought.**
  This applies equally to logs, metrics, and traces. It does not get
  enforced by tools — it gets enforced by deliberate configuration at
  the seam where data enters the indexed store.

- **Evidence-first beats hypothesis-first.** The Phase 7 handoff
  diagnosed the logging issue as "missing arguments." Code inspection
  showed the diagnosis was wrong. Captured raw data showed the actual
  failure mode and surfaced a fourth issue nobody predicted. The
  pattern: hypothesize, then capture structured data, then let the
  data correct the hypothesis.

- **Code to stability and health, not to discipline.** Written
  conventions ("we'll review every new metric for cardinality") fail
  silently at scale. Hard limits ("Prometheus rejects scrapes over N
  series") fail loudly in dev, before production. Pick the failure
  mode that surfaces problems while they're still cheap to fix.

- **Working-looking is not working.** A 22-day-silent-failure that
  produces no errors visible to dashboards or normal operation is the
  most dangerous kind of bug. The discipline that catches these is
  *checking that things you expect to be there are actually there*,
  not *checking that things you expect to be working are working*.

- **Three-am rule applies to architecture, not just code.** Two
  config files enforcing the same policy that can drift apart is
  worse than one correctly-configured file. Defense in depth means
  *different policies at different layers*, not *the same policy
  duplicated across layers*.

- **Runbooks are tested against real clusters.** Established at the
  end of Phase 7. Documentation that has not been validated by
  execution is hypothesis, not record. The Phase 2 rewrite is not
  done until a cold rebuild has been validated against it.

These belong somewhere more permanent than a handoff — probably an
ADR or a contributing-principles doc in the Scaffold Rack repo. That
is its own work item, deferred.

---

## Suggested first steps for the next chat

1. Read this document and the artifacts listed above, in the order
   given. The order matters — the existing runbook gives shape to
   what's being replaced, the Phase 7 migration runbook gives the
   technical content of what's replacing it.
2. Confirm the broken state of container log collection matches what
   is described here. Re-run the Loki labels query and check the
   DaemonSet logs. Do not accept the diagnosis on trust.
3. Confirm the live cluster state matches what `manifests/` and
   `CONTEXT.md` describe. Drift between live state and tracked state
   is the kind of thing that invalidates this whole effort.
4. Capture exact installed Helm chart versions from the live cluster
   (`helm list -A --output=json`). These become the version pins
   in the rewritten runbook.
5. Plan the rewrite as a structured document edit, not a new file.
   `rebuild-runbook.md` keeps its overall structure (Pre-flight,
   Phase 1, Phase 2, Phase 4, Phase 5a, Phase 5b). Phase 2 gets
   rewritten in place. Phase 5a probably gets renamed and shrunk
   (Grafana dashboards live in Phase 2, not their own phase). The
   rest stays.
6. Stage the change as commits applied in this order:
   1. Capture "before" evidence — Loki labels, helm list, kubectl
      get all output. Land in `documentation/evidence/phase-2-rewrite-before/`.
   2. Add `manifests/fluent-bit-values.yaml`.
   3. Update `rebuild-runbook.md` Phase 2 to LGTM-native including
      Fluent Bit. Update Phase 5a as needed. Pin all chart versions
      runbook-wide.
   4. Update `CONTEXT.md` Versions table to reflect Fluent Bit and
      any other new pins.
   5. `git rm` the legacy ECK manifests and stale Kibana ndjson exports.
   6. **Validate by cold rebuild on a fresh cluster.** Iterate the
      runbook content as issues are discovered. This step takes as
      long as it takes.
   7. Capture "after" evidence post-validation. Land in
      `documentation/evidence/phase-2-rewrite-after/`.
   8. Commit and push the validated set.

---

## Open questions for the next chat to resolve

- **Fluent Bit chart version.** Pick the latest stable at deployment
  time and pin it. Capture in `CONTEXT.md`'s Versions table.
- **Fluent Bit OTLP output configuration.** Fluent Bit's OTel output
  plugin has matured but specifics matter. Confirm during deployment
  that it produces the resource attribute conventions the gateway
  collector expects, especially `service.name` semantics for
  non-application pods. Where documentation is unclear, run a small
  test and capture the actual behavior as evidence rather than
  assuming.
- **Phase 5a fate.** The current Phase 5a is "Kibana Dashboards." It
  needs to either be deleted (if Grafana dashboards are fully covered
  in Phase 2) or rewritten as a Grafana-equivalent. Probably the
  former — the existing `grafana-dashboard-sensor-demo.yaml` ConfigMap
  is provisioned during Phase 2 install per the LGTM-native pattern
  and doesn't need its own phase.
- **Phase 4 dependency check.** Phase 4 (GitOps and Application
  Deployments) references Phase 2 outputs. Read it carefully during
  the rewrite to make sure no Phase 2 changes break Phase 4
  assumptions about resource names, namespace contents, or Vault
  paths.
- **How rigorous is "cold rebuild"?** Two reasonable interpretations:
  (a) `cluster-delete.sh` followed by full runbook from `cluster-create.sh`
  on the existing `devajk01` host, or (b) wiping the host and
  starting from a totally clean Debian install. The first is much
  faster and probably sufficient. The second is the gold standard
  but expensive. Pick (a) unless there's a specific reason to do (b).
- **Whether the broken DaemonSet metrics scrape was being used.**
  Confirmed in the predecessor chat that kube-prometheus-stack
  already covers kubelet/cadvisor with nine healthy targets, so the
  metrics pipeline dies with the DaemonSet without operational
  consequence. Verify this is still true at deployment time before
  deletion.
