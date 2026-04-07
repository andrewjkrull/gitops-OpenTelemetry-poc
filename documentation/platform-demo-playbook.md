# Platform Demo Playbook

A reference for running the live leadership demo and extending the platform.
Covers Phase 5b (latency injection via GitOps) and the procedures for adding
new services and promoting deployments across environments.

---

## Overview

The demo tells one story through three live moments:

1. **GitOps in action** — a git commit is the only way to change cluster state.
   No `kubectl`, no SSH, no manual config edits on servers.

2. **Observability responds in real time** — every change is immediately visible
   in Kibana. The dashboard reacts within 30 seconds of an ArgoCD sync.

3. **Vault delivers secrets silently** — no secret ever appears in a manifest,
   an image, an environment variable, or a CI log.

---

## Pre-demo checklist

Run through this before any audience-facing session. All steps assume a healthy
cluster with applications running.

### Verify the pipeline is live

```bash
kubectl get pods -n sensor-dev
# Expected: 3 pods, all 2/2 Running
```

Check sensor-producer is publishing:

```bash
kubectl logs -n sensor-dev \
  $(kubectl get pod -n sensor-dev -l app=sensor-producer \
    -o jsonpath='{.items[0].metadata.name}') \
  -c sensor-producer --tail=5
# Expected: [trace:xxxxxxxx] Published sensorId=... value=... interval=1000ms
```

Check mqtt-bridge is forwarding:

```bash
kubectl logs -n sensor-dev \
  $(kubectl get pod -n sensor-dev -l app=mqtt-bridge \
    -o jsonpath='{.items[0].metadata.name}') \
  -c mqtt-bridge --tail=5
# Expected: [trace:xxxxxxxx] Bridged sensorId=... value=... trend=...
# Also shows: Bridge delay: 0ms  (confirms delay is off at baseline)
```

### Verify Kibana dashboard is populated

1. Open `https://kibana.test`
2. Navigate to **Dashboards** → `Sensor Demo — Observability Overview`
3. Set time range to **Last 1 hour**, auto-refresh **30 seconds**
4. Confirm all six panels show data — no "No results" panels

### Verify ArgoCD is synced

Open `https://argocd.test` — `sensor-demo-dev` should show **Synced** and **Healthy**.

### Verify the ConfigMap is at baseline

```bash
kubectl get configmap sensor-config -n sensor-dev \
  -o jsonpath='{.data.SENSOR_INTERVAL_MS} {.data.BRIDGE_DELAY_MS}'
# Expected: 1000 0
```

If `BRIDGE_DELAY_MS` is not `0` from a previous demo run, reset it now:

1. Open `https://gitea.test/poc/sensor-demo-deploy`
2. Navigate to `envs/dev/kustomization.yaml`
3. Find the `op: add` patch for `BRIDGE_DELAY_MS` and set the value to `"0"`
4. Commit to `main`
5. Wait for ArgoCD to sync (30–60 seconds)
6. Verify: re-run the kubectl check above

---

## Phase 5b — Latency injection demo

### How it works

`BRIDGE_DELAY_MS` is a key in the `sensor-config` ConfigMap. When it is greater
than zero, `mqtt-bridge` calls `Task.Delay` for that many milliseconds inside the
`bridge-sensor-reading` span, before the Kafka publish. Because the delay sits
inside the span, it adds directly to the span duration and shows up immediately
in Kibana's latency panels.

This demonstrates the GitOps principle: the change travels through git → ArgoCD
→ ConfigMap update → pod picks up the new env var value — with zero code
deployment or container restart required.

> **Why does the pod restart?** Kubernetes does not automatically restart pods
> when a referenced ConfigMap changes — `envFrom: configMapRef` is evaluated
> at pod startup only. Reloader (Stakater) watches for ConfigMap changes and
> triggers a rolling restart of any Deployment annotated with
> `reloader.stakater.com/auto: "true"`. All three app Deployments carry this
> annotation. When ArgoCD syncs the updated ConfigMap, Reloader detects the
> change within seconds and performs the rollout. The new pod starts with the
> updated values. This is why the demo works: git push → ArgoCD syncs ConfigMap
> → Reloader triggers rollout → new pod picks up `BRIDGE_DELAY_MS`.

### Demo sequence

**Setup:** have two browser tabs open side by side —
`https://argocd.test` and `https://kibana.test` on the Sensor Demo dashboard.
Set Kibana to **Last 15 minutes**, auto-refresh **30 seconds**.

#### Step 1 — Show the baseline

Point to Kibana and narrate:

> "This is our sensor platform running right now. Three services — a producer,
> a bridge, and a consumer — passing temperature readings across MQTT and Kafka.
> Every hop is instrumented with OpenTelemetry. The Service Latency panel shows
> normal processing latency in the low single-digit millisecond range. We have
> about one event per second per sensor."

#### Step 2 — Make the change in Gitea

1. Open `https://gitea.test/poc/sensor-demo-deploy`
2. Navigate to `envs/dev/kustomization.yaml`
3. Click the **pencil (edit)** icon
4. Find the `op: add` patch for `BRIDGE_DELAY_MS` and change the value:
   ```
   value: "2000"
   ```
5. Commit message: `demo: inject 2s latency into mqtt-bridge`
6. Click **Commit Changes** directly to `main`

Narrate:

> "I just pushed a single line to git. That's the only action I've taken —
> no kubectl, no SSH into the cluster, no config file edits on a server.
> Now watch ArgoCD."

#### Step 3 — Watch ArgoCD sync

Switch to the ArgoCD tab. Within 30–60 seconds `sensor-demo-dev` will move
through **OutOfSync** → **Syncing** → **Synced**.

Narrate:

> "ArgoCD has detected the change in the deploy repo and is reconciling the
> cluster to match. It's doing a rolling restart of mqtt-bridge with the
> new ConfigMap value — zero downtime."

#### Step 4 — Watch Kibana respond

Switch to Kibana. Within 60–90 seconds of the sync completing:

- **Service Latency Over Time** — the `mqtt-bridge` line climbs to ~2000ms.
  `event-consumer` may also show slightly elevated latency as messages arrive
  later from the bridge.
- **Event Throughput by Sensor** — may show a brief dip or gap during the
  rolling restart window, then recover at a reduced rate (events are still
  arriving, just 2 seconds apart in the bridge).

Narrate:

> "The dashboard has reacted. We can see the bridge latency has jumped to
> 2 seconds exactly — matching the value we just pushed to git. Nobody touched
> the cluster directly. The platform detected the git change, synced it, and
> now Elasticsearch has the telemetry to prove it happened."

#### Step 5 — Show recovery (optional but strong)

1. Return to `https://gitea.test/poc/sensor-demo-deploy`
2. Navigate to `envs/dev/kustomization.yaml`
3. Click the **pencil (edit)** icon
4. Find the `op: add` patch for `BRIDGE_DELAY_MS` and set the value back:
   ```
   value: "0"
   ```
5. Commit message: `demo: remove injected latency — recovering`

Wait for ArgoCD sync, then Kibana — the latency line drops back to baseline.

Narrate:

> "And we can see it recover. Same mechanism — a git commit, ArgoCD syncs,
> the change takes effect. If this were a production incident, every step
> of this remediation would be in git history with a timestamp and an author."

### Verifying the delay is active

**Step 1 — Confirm the ConfigMap was updated by ArgoCD:**

```bash
kubectl get configmap sensor-config -n sensor-dev \
  -o jsonpath='{.data.BRIDGE_DELAY_MS}'
# Expected: 2000  (or whatever value was set)
```

If this still shows `0` ArgoCD has not synced yet — wait another 30 seconds and re-run.

To force an immediate sync without waiting for the polling interval:

- **UI:** Open `https://argocd.test` → click `sensor-demo-dev` → click **Sync** → **Synchronize**
- **CLI (kubectl — works with devops-toolkit):**
  ```bash
  kubectl annotate application sensor-demo-dev     -n argocd     argocd.argoproj.io/refresh=hard     --overwrite
  ```
  This triggers an immediate hard refresh — ArgoCD re-reads the deploy repo and syncs
  without waiting for the next polling interval.

**Step 2 — Confirm the pod picked up the new value:**

After a `BRIDGE_DELAY_MS` change and pod restart, confirm the new value was
picked up:

```bash
kubectl logs -n sensor-dev \
  $(kubectl get pod -n sensor-dev -l app=mqtt-bridge \
    -o jsonpath='{.items[0].metadata.name}') \
  -c mqtt-bridge --tail=20
# Expected startup lines:
#   Bridge delay: 2000ms
# And per-message:
#   [trace:xxxxxxxx] Bridged sensorId=sensor-01 value=22.4 trend=rising
```

If the log still shows `Bridge delay: 0ms` after the sync, the pod has not
restarted yet. Watch for the rollout to complete:

```bash
kubectl rollout status deployment/mqtt-bridge -n sensor-dev
# Expected: successfully rolled out
```

**Quick grep to confirm Reloader triggered the rollout:**

```bash
kubectl logs -n kube-system \
  $(kubectl get pod -n kube-system -l app.kubernetes.io/name=reloader \
    -o jsonpath='{.items[0].metadata.name}') \
  --tail=20 | grep -i "mqtt-bridge\|sensor-config"
# Expected: Changes Detected in mqtt-bridge ... Rolling upgrade
```

### Developer troubleshooting workflow

If Kibana is not reacting after a `BRIDGE_DELAY_MS` change, work through this
checklist top to bottom — each step rules out a layer:

**1. Did ArgoCD sync?**

```bash
kubectl get configmap sensor-config -n sensor-dev \
  -o jsonpath='{.data.BRIDGE_DELAY_MS}'
# If still 0: ArgoCD hasn't synced. Force it:
kubectl annotate application sensor-demo-dev \
  -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

**2. Did Reloader trigger the rollout?**

```bash
kubectl rollout status deployment/mqtt-bridge -n sensor-dev
# If stuck: check Reloader logs (command above)
# If Reloader pod is missing: helm install reloader (see rebuild-runbook Step 27)
```

**3. Did the new pod start with the updated value?**

```bash
kubectl logs -n sensor-dev \
  $(kubectl get pod -n sensor-dev -l app=mqtt-bridge \
    -o jsonpath='{.items[0].metadata.name}') \
  -c mqtt-bridge --tail=5 | grep "Bridge delay"
# If still shows old value: pod may not have fully restarted — wait 30s and retry
```

**4. Is the delay showing in traces?**

In Kibana Discover (OTel Traces index), filter:
- `resource.attributes.service.name: mqtt-bridge`
- `name: bridge-sensor-reading`
- Sort by `@timestamp` descending

Check the `duration` field — with a 2000ms delay expect values around `2,000,000,000`
(nanoseconds). If spans are absent entirely, check that the OTel gateway pod is
running: `kubectl get pods -n observability`.

**5. Is Kibana's time range covering the new data?**

Switch to **Last 15 minutes** during active demos. The Service Latency panel
aggregates over the selected window — if the window is too wide the spike is
visually diluted by the pre-change baseline.

### Kibana panel reference for the demo

| Panel | What to watch for |
|---|---|
| Service Latency Over Time | `mqtt-bridge` line climbs to injected delay value |
| Event Throughput by Sensor | Brief dip during rolling restart, recovers |
| Error Span Rate | Should remain flat — delay alone does not cause errors |
| Sensor Trend Distribution | Unaffected — trend calculation is in the bridge logic |

> **Note on Y-axis units:** the Service Latency panel displays milliseconds.
> The raw `duration` field in Elasticsearch is nanoseconds — the Kibana Lens
> formula divides by 1,000,000 to convert. A 2000ms delay will show as ~2000
> on the Y-axis.

---

## Phase 5c — Environment promotion

> **Status:** scaffolding is in place. The full promotion workflow (dev → qa
> → prod) is being finalised. This section will be completed in a future
> session.

### What is already built

- `envs/dev`, `envs/qa`, `envs/prod` Kustomize overlays in `sensor-demo-deploy`
- `sensor-demo-qa` and `sensor-demo-prod` ArgoCD Applications — both pointing
  at `main`, both set to **manual sync**
- `gitea-registry` pull secrets present in `sensor-qa` and `sensor-prod`
  (created by `gitea-init.sh`)

### Manual promotion (current)

To promote whatever is in dev to QA:

1. Open `https://argocd.test`
2. Click `sensor-demo-qa`
3. Click **Sync** → **Synchronize**
4. Pods start in `sensor-qa` with the same base manifests as `sensor-dev`

Repeat for `sensor-demo-prod` to promote to production.

> The QA and production overlays currently use the same `busybox:latest`
> standin images as the initial deploy-repo scaffolding. Image tag promotion
> (pinning specific dev SHA tags into qa/prod overlays) is the next piece to
> design and build.

---

## Adding a new service to the platform

This platform is designed to be extended. These steps onboard a fourth
service — the example uses `alert-engine` as the service name throughout.

### Step 1 — Create the Gitea repo

```bash
GITEA_PASS=$(gitea-token)

docker run --rm --network host devops-toolkit:latest \
  curl -sk -X POST \
  -u "poc-admin:${GITEA_PASS}" \
  -H "Content-Type: application/json" \
  "https://gitea.test/api/v1/orgs/poc/repos" \
  -d '{"name":"alert-engine","private":false,"auto_init":true,"default_branch":"main"}'
```

Verify it appeared:

```bash
docker run --rm --network host devops-toolkit:latest \
  curl -sk -u "poc-admin:${GITEA_PASS}" \
  "https://gitea.test/api/v1/orgs/poc/repos" \
  | docker run --rm -i devops-toolkit:latest jq -r '.[].name' | sort
# Expected: alert-engine appears in the list
```

### Step 2 — Add Vault auth role

Edit `scripts/vault-init.sh` and add the new role alongside the existing three:

```bash
vault write auth/kubernetes/role/alert-engine \
  bound_service_account_names=alert-engine \
  bound_service_account_namespaces=sensor-dev,sensor-qa,sensor-prod \
  policies=alert-engine-policy \
  ttl=1h
```

Then run vault-init.sh to apply:

```bash
bash ${POC_DIR}/scripts/vault-init.sh
```

> Create a matching Vault policy (`alert-engine-policy`) before running this,
> or the role write will succeed but the policy will not grant any access.

### Step 3 — Write base manifests in the deploy repo

Clone `sensor-demo-deploy` locally, then add:

**`base/alert-engine.yaml`** — copy `base/mqtt-bridge.yaml` as a template and
update: the Deployment name, labels, ServiceAccount name, Vault role annotation,
container name, and image field.

The image placeholder must match the Kustomize override name exactly:

```yaml
containers:
  - name: alert-engine
    image: alert-engine    # must match 'name:' in the images block
```

**`base/serviceaccounts.yaml`** — add the new ServiceAccount:

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: alert-engine
imagePullSecrets:
  - name: gitea-registry
```

**`base/kustomization.yaml`** — add the new resource:

```yaml
resources:
  - serviceaccounts.yaml
  - configmap.yaml
  - sensor-producer.yaml
  - mqtt-bridge.yaml
  - event-consumer.yaml
  - alert-engine.yaml    # add this line
```

### Step 4 — Add image override to env overlays

In each of `envs/dev/kustomization.yaml`, `envs/qa/kustomization.yaml`, and
`envs/prod/kustomization.yaml`, add the new service to the `images:` block:

```yaml
images:
  - name: alert-engine
    newName: gitea.test/poc/alert-engine
    newTag: latest    # CI will update this for dev
```

### Step 5 — Write the CI workflow

Copy `.gitea/workflows/build.yml` from any existing app repo into
`apps/alert-engine/.gitea/workflows/build.yml` and update the two variables
at the top:

```yaml
env:
  APP_NAME: alert-engine
  IMAGE: gitea.test/poc/alert-engine
```

No other changes are needed — the rest of the workflow is generic.

### Step 6 — Push app source to trigger CI

Once the app source is ready in `apps/alert-engine/`:

```bash
cd ${POC_DIR}/apps/alert-engine
git init
git remote add origin https://poc-admin:$(gitea-token)@gitea.test/poc/alert-engine.git
git add .
git commit -m "feat: initial alert-engine service"
git push -u origin main
```

Watch the Actions tab for the build:

```
https://gitea.test/poc/alert-engine/actions
```

After a successful build, ArgoCD syncs `sensor-dev` and the new pod starts
alongside the existing three.

---

## Promoting to QA and Production

`sensor-demo-qa` and `sensor-demo-prod` are set to manual sync in ArgoCD.
They watch the same deploy repo as dev but require explicit approval before
any change takes effect.

### Promote dev → QA

1. Open `https://argocd.test`
2. Click `sensor-demo-qa`
3. Click **Sync** → **Synchronize**
4. Pods start in `sensor-qa` — same images as `sensor-dev` at that commit

```bash
kubectl get pods -n sensor-qa
# Expected: 3 pods, all 2/2 Running
```

The `gitea-registry` pull secret is already in `sensor-qa` (created by
`gitea-init.sh`). No additional setup is needed for the first promotion.

### Promote QA → Production

Same process for `sensor-demo-prod`:

1. Open `https://argocd.test`
2. Click `sensor-demo-prod`
3. Click **Sync** → **Synchronize**
4. Pods start in `sensor-prod`

```bash
kubectl get pods -n sensor-prod
# Expected: 3 pods, all 2/2 Running
```

### Verify promoted pods are healthy

After a QA or prod promotion, verify the Vault Agent is injecting secrets
correctly (the apps need Vault auth roles bound to the target namespace):

```bash
# Check for 2/2 Running (app + vault-agent sidecar)
kubectl get pods -n sensor-qa

# Spot-check that vault secrets rendered
kubectl exec -n sensor-qa \
  $(kubectl get pod -n sensor-qa -l app=sensor-producer \
    -o jsonpath='{.items[0].metadata.name}') \
  -c sensor-producer -- ls /vault/secrets/
# Expected: kafka.env  mqtt.env  redis.env
```

> If pods start as `1/2` with the vault-agent container in `Init` state,
> the Vault auth role for that namespace is missing. Verify that all three
> namespaces (`sensor-dev`, `sensor-qa`, `sensor-prod`) are listed in
> `bound_service_account_namespaces` for each role in `vault-init.sh`.
