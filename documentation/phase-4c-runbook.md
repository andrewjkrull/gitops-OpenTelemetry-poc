# Phase 4c Runbook — App Scaffolds, CI Pipeline, and Distributed Traces

## What this phase builds

Phase 4c replaces the busybox placeholder pods from Phase 4b with three real .NET 6
applications that communicate across MQTT, Redis, and Kafka. Every message carries a
W3C trace context header, producing end-to-end distributed traces visible in Kibana.

A Gitea Actions CI pipeline is wired to each app repo. When you push to `main`, the
pipeline builds a Docker image, pushes it to the Gitea container registry, commits
the new image tag to the deploy repo, and ArgoCD syncs `sensor-dev` automatically.

**What you will have at the end:**
- Three .NET 6 apps running as real container images in `sensor-dev`
- Vault Agent injecting credentials into every pod at startup
- Traces flowing: `sensor-producer` → MQTT → `mqtt-bridge` → Kafka → `event-consumer` → Elasticsearch
- CI pipeline: push to app repo → build → push to registry → ArgoCD syncs dev

**Prerequisites:**
- Phases 1–4b complete and verified
- `kubectl get applications -n argocd` shows `sensor-demo-dev` Synced/Healthy
- `kubectl get pods -n sensor-dev` shows 3 pods 2/2 Running (busybox standins)
- Gitea at `https://gitea.test` with `poc` org and four repos
- ArgoCD at `https://argocd.test`
- Messaging infrastructure running in `messaging` namespace

---

## Overview of what gets built

```
apps/sensor-producer/    ← publishes temp readings to MQTT every N ms
apps/mqtt-bridge/        ← subscribes MQTT, enriches via Redis, publishes to Kafka
apps/event-consumer/     ← consumes Kafka, writes results to Redis, logs with traceId

Each app has:
  Program.cs             ← .NET 6 Worker Service with OTel instrumentation
  <app>.csproj           ← dependencies: MQTTnet, Confluent.Kafka, StackExchange.Redis, OTel
  Dockerfile             ← multi-stage build targeting gitea.test/poc/<app>:<sha>
  .gitea/workflows/
    build.yml            ← CI: build → push → update deploy repo → ArgoCD syncs
```

The trace chain across non-HTTP protocols:

```
sensor-producer starts root span
  └── writes W3C traceparent into MQTT message JSON payload
mqtt-bridge extracts traceparent → creates child span (same traceId)
  └── writes updated traceparent into Kafka message JSON payload
event-consumer extracts traceparent → creates child span (same traceId)
  └── logs [trace:xxxxxxxx] with traceId prefix → correlatable in Kibana
```

---

## Step 1 — Verify app source files are in place

The app source should already be in `${POC_DIR}/apps/`. Confirm:

```bash
find ${POC_DIR}/apps -name "Program.cs" | sort
find ${POC_DIR}/apps -name "*.csproj" | sort
find ${POC_DIR}/apps -name "Dockerfile" | sort
```

Expected output — three of each:
```
.../apps/event-consumer/Program.cs
.../apps/mqtt-bridge/Program.cs
.../apps/sensor-producer/Program.cs
```

If any are missing, they need to be written before proceeding. See the architecture
document at `documentation/sensor-demo-architecture.md` for the full service design.

**Critical .NET 6 compatibility note:** the apps use `Host.CreateDefaultBuilder` —
not `Host.CreateApplicationBuilder` which was introduced in .NET 7 and will not compile
under the `net6.0` target framework. If you see `CS0117: 'Host' does not contain a
definition for 'CreateApplicationBuilder'`, the wrong host builder is being used.

---

## Step 2 — Build and verify images locally

Before pushing to Gitea, confirm each app builds and produces a valid image. This
catches compilation errors before CI is involved.

```bash
# Build sensor-producer
cd ${POC_DIR}/apps/sensor-producer
docker build -t gitea.test/poc/sensor-producer:test .

# Build mqtt-bridge
cd ${POC_DIR}/apps/mqtt-bridge
docker build -t gitea.test/poc/mqtt-bridge:test .

# Build event-consumer
cd ${POC_DIR}/apps/event-consumer
docker build -t gitea.test/poc/event-consumer:test .
```

Each build should complete with `FINISHED` and no errors. The images are multi-stage:
the SDK image compiles the app, the runtime-only image runs it. Final images are ~200MB.

**Common build errors:**

| Error | Cause | Fix |
|-------|-------|-----|
| `CS1525: Invalid expression term '['` | C# 11 collection syntax in .NET 6 | Replace `["a","b"]` with `new[] {"a","b"}` |
| `CS0117: 'Host' does not contain CreateApplicationBuilder` | .NET 7 API used | Use `Host.CreateDefaultBuilder` |
| `CS0103: The name 'Host' does not exist` | Missing hosting package | Add `Microsoft.Extensions.Hosting 6.0.1` to .csproj |

---

## Step 3 — Push test images to Gitea registry

Verify the registry accepts pushes before writing CI workflows.

```bash
# Login to Gitea registry
GITEA_PASS=$(gitea-token)
echo "${GITEA_PASS}" | docker login gitea.test -u poc-admin --password-stdin

# Push all three test images
docker push gitea.test/poc/sensor-producer:test
docker push gitea.test/poc/mqtt-bridge:test
docker push gitea.test/poc/event-consumer:test
```

Verify they landed:

```bash
GITEA_PASS=$(gitea-token)
docker run --rm --network host devops-toolkit:latest \
  curl -sk -u "poc-admin:${GITEA_PASS}" \
  "https://gitea.test/api/v1/packages/poc?type=container&limit=10" \
  | docker run --rm -i devops-toolkit:latest jq -r '.[].name' | sort -u
```

Expected: `event-consumer`, `mqtt-bridge`, `sensor-producer`

---

## Step 4 — Configure the Gitea Actions runner

The runner runs on the WSL2 host (not inside k3d) as a host Docker container.
k3d nodes don't have a Docker socket, so the runner must run on the host where
Docker is available.

### 4a — Verify runner config exists

```bash
ls ${POC_DIR}/documentation/gitea-runner-config.yml
```

If missing, generate it:

```bash
docker exec gitea-runner act_runner generate-config \
  > ${POC_DIR}/documentation/gitea-runner-config.yml
```

Then edit it with these required values under `container:`:

```yaml
container:
  network: "host"          # job containers share host network — required for gitea.test access
  options: >-
    -v /etc/hosts:/etc/hosts:ro
    -v /home/andrew/Projects/poc/vault/poc-ca.crt:/usr/local/share/ca-certificates/poc-ca.crt:ro
    -e SSL_CERT_DIR=/usr/local/share/ca-certificates
    -e GIT_SSL_CAINFO=/usr/local/share/ca-certificates/poc-ca.crt
    -e NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/poc-ca.crt
    -e SSL_CERT_FILE=/usr/local/share/ca-certificates/poc-ca.crt
  valid_volumes:
    - '**'
  force_pull: false        # don't re-pull job image every run

runner:
  labels:
    - "ubuntu-latest:docker://gitea/runner-images:ubuntu-latest"
    - "ubuntu-24.04:docker://gitea/runner-images:ubuntu-latest"
    - "ubuntu-22.04:docker://gitea/runner-images:ubuntu-latest"
```

**Why these settings matter:**
- `network: host` — job containers see `127.0.0.1:443` as Traefik (not their own loopback)
- `/etc/hosts` mount — job containers resolve `gitea.test` to `127.0.0.1`
- CA cert mounts + env vars — git and Node trust the Vault-issued certificate
- `gitea/runner-images:ubuntu-latest` — has git pre-installed; `node:20-bullseye-slim` does not

### 4b — Start the runner

`poc-toolkit.zsh` manages the runner via `runner-start` / `runner-stop`.
The `poc-start` function calls `runner-start` automatically on session restart.

```bash
runner-stop
docker rm gitea-runner 2>/dev/null || true

# Copy config into data directory before starting
mkdir -p ${POC_DIR}/tmp/gitea-runner
cp ${POC_DIR}/documentation/gitea-runner-config.yml \
   ${POC_DIR}/tmp/gitea-runner/config.yml

# Read fresh registration token
RUNNER_TOKEN=$(kubectl get secret gitea-runner-token -n gitea \
  -o jsonpath='{.data.token}' | base64 -d | tr -d '\r\n')

docker run -d \
  --name gitea-runner \
  --restart unless-stopped \
  --network host \
  -v /etc/hosts:/etc/hosts:ro \
  -v ${POC_DIR}/vault/poc-ca.crt:/usr/local/share/ca-certificates/poc-ca.crt:ro \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ${POC_DIR}/tmp/gitea-runner:/data \
  -e GITEA_INSTANCE_URL=https://gitea.test \
  -e GITEA_RUNNER_REGISTRATION_TOKEN="${RUNNER_TOKEN}" \
  -e GITEA_RUNNER_NAME=poc-runner \
  -e CONFIG_FILE=/data/config.yml \
  -e SSL_CERT_DIR=/usr/local/share/ca-certificates \
  gitea/act_runner:latest

sleep 5 && docker logs gitea-runner --tail=10
```

Expected in logs: `Runner registered successfully` and `declare successfully`.

**Critical:** `CONFIG_FILE=/data/config.yml` is required. The runner does NOT
auto-discover `config.yml` — it only loads it when this env var is set explicitly.

### 4c — Set org-level CI secrets

These secrets are available to all workflows in the `poc` org:

```bash
GITEA_PASS=$(gitea-token)

# Registry login credentials
docker run --rm --network host devops-toolkit:latest \
  curl -sk -X PUT \
  -u "poc-admin:${GITEA_PASS}" \
  -H "Content-Type: application/json" \
  "https://gitea.test/api/v1/orgs/poc/actions/secrets/REGISTRY_USER" \
  -d '{"data":"poc-admin"}'

docker run --rm --network host devops-toolkit:latest \
  curl -sk -X PUT \
  -u "poc-admin:${GITEA_PASS}" \
  -H "Content-Type: application/json" \
  "https://gitea.test/api/v1/orgs/poc/actions/secrets/REGISTRY_PASSWORD" \
  -d "{\"data\":\"${GITEA_PASS}\"}"

# Deploy token — used by CI to commit image tags to sensor-demo-deploy
# Delete old token first (Gitea tokens cannot be read back after creation)
docker run --rm --network host devops-toolkit:latest \
  curl -sk -X DELETE \
  -u "poc-admin:${GITEA_PASS}" \
  "https://gitea.test/api/v1/users/poc-admin/tokens/ci-deploy"

DEPLOY_TOKEN=$(docker run --rm --network host devops-toolkit:latest \
  curl -sk -X POST \
  -u "poc-admin:${GITEA_PASS}" \
  -H "Content-Type: application/json" \
  "https://gitea.test/api/v1/users/poc-admin/tokens" \
  -d '{"name":"ci-deploy","scopes":["write:repository","read:repository"]}' \
  | docker run --rm -i devops-toolkit:latest jq -r '.sha1')

docker run --rm --network host devops-toolkit:latest \
  curl -sk -X PUT \
  -u "poc-admin:${GITEA_PASS}" \
  -H "Content-Type: application/json" \
  "https://gitea.test/api/v1/orgs/poc/actions/secrets/CI_DEPLOY_TOKEN" \
  -d "{\"data\":\"${DEPLOY_TOKEN}\"}"

# Verify all three secrets exist
docker run --rm --network host devops-toolkit:latest \
  curl -sk -u "poc-admin:${GITEA_PASS}" \
  "https://gitea.test/api/v1/orgs/poc/actions/secrets" \
  | docker run --rm -i devops-toolkit:latest jq -r '.[].name'
```

Expected: `CI_DEPLOY_TOKEN`, `REGISTRY_PASSWORD`, `REGISTRY_USER`

---

## Step 5 — Create the image pull secret

k3d nodes cannot pull from `gitea.test` without credentials. The pull secret
is attached to the ServiceAccounts in the deploy repo, so every pod that uses
those accounts inherits it automatically.

```bash
GITEA_PASS=$(gitea-token)

for NS in sensor-dev sensor-qa sensor-prod; do
  kubectl create secret docker-registry gitea-registry \
    -n ${NS} \
    --docker-server=gitea.test \
    --docker-username=poc-admin \
    --docker-password="${GITEA_PASS}" \
    --dry-run=client -o yaml > /tmp/gitea-registry-${NS}.yaml
  kubectl apply -f /tmp/gitea-registry-${NS}.yaml
  echo "Created gitea-registry in ${NS}"
done
```

**Note:** `gitea-init.sh` creates these automatically on fresh cluster builds.
This step is only needed if `gitea-init.sh` was run before Phase 4c or if
the secrets were lost.

Verify the `serviceaccounts.yaml` in `sensor-demo-deploy/base/` has
`imagePullSecrets` on all three ServiceAccounts:

```bash
grep -A2 "imagePullSecrets" \
  /tmp/deploy-repo-check/base/serviceaccounts.yaml
```

Expected for each ServiceAccount:
```yaml
imagePullSecrets:
  - name: gitea-registry
```

---

## Step 6 — Push app source to Gitea and trigger first CI build

The `app-repos-init.sh` script initialises git repos in each app directory,
writes the CI workflow, commits everything, and pushes to Gitea.

```bash
bash ${POC_DIR}/scripts/app-repos-init.sh
```

This push triggers the first CI build in each repo. Watch the Actions tab:

```
https://gitea.test/poc/sensor-producer/actions
https://gitea.test/poc/mqtt-bridge/actions
https://gitea.test/poc/event-consumer/actions
```

Each workflow runs these steps:
1. **Checkout source** — clones the app repo using git (requires CA trust + host network)
2. **Set image tag** — extracts first 8 chars of commit SHA
3. **Login to Gitea registry** — uses `REGISTRY_USER` and `REGISTRY_PASSWORD` secrets
4. **Build image** — `docker build -t gitea.test/poc/<app>:<sha> .`
5. **Push image** — pushes both `:<sha>` and `:latest` tags
6. **Update deploy repo** — clones `sensor-demo-deploy`, updates `envs/dev/kustomization.yaml`
   with the new image tag using a Python script, commits and pushes
7. **ArgoCD auto-sync** — detects the deploy repo change within ~30s, syncs `sensor-dev`

**If a build fails:**
- Check the Actions tab in Gitea for the step-by-step log
- `Checkout source` failures: usually TLS or network — verify runner config
- `Build image` failures: usually compilation errors — check Program.cs
- `Update deploy repo` failures: usually the Python tag update script — check kustomization.yaml structure

---

## Step 7 — Verify pods are running real images

After all three CI builds complete and ArgoCD syncs:

```bash
kubectl get pods -n sensor-dev
```

Expected: three pods, all 2/2 Running (app container + vault-agent sidecar).

Confirm real images (not busybox):

```bash
kubectl get pods -n sensor-dev \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
```

Expected:
```
event-consumer-<hash>    gitea.test/poc/event-consumer:<sha>
mqtt-bridge-<hash>       gitea.test/poc/mqtt-bridge:<sha>
sensor-producer-<hash>   gitea.test/poc/sensor-producer:<sha>
```

---

## Step 8 — Verify messaging credentials

The apps read credentials from `/vault/secrets/*.env` — injected by Vault Agent.
These must match what the messaging services (Mosquitto, Redis, Kafka) expect.

After a fresh cluster build `messaging-init.sh` writes consistent credentials
to both Kubernetes Secrets and Vault KV. If there has been any manual intervention
or crash recovery, they may have drifted.

**Check sensor-producer logs:**

```bash
kubectl logs -n sensor-dev \
  $(kubectl get pod -n sensor-dev -l app=sensor-producer \
    -o jsonpath='{.items[0].metadata.name}') \
  -c sensor-producer --tail=20
```

**Healthy output looks like:**
```
info: ProducerWorker[0]  MQTT connected
info: ProducerWorker[0]  Publishing every 1000ms
info: ProducerWorker[0]  [trace:a1b2c3d4] Published sensorId=sensor-01 value=22.4 interval=1000ms
```

**If you see `MQTT connect failed: NotAuthorized`:**

The Mosquitto password in Vault doesn't match what Mosquitto has. Test directly:

```bash
MQTT_PASS=$(docker run --rm --network host \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  -e VAULT_TOKEN="$(cat ${POC_DIR}/vault/root-token)" \
  devops-toolkit:latest \
  vault kv get -field=password secret/apps/mqtt)

kubectl run mqtt-test --rm -it --restart=Never \
  -n messaging \
  --image=eclipse-mosquitto:2.0 \
  -- mosquitto_pub \
    -h mosquitto.messaging.svc.cluster.local \
    -p 1883 -u sensor -P "${MQTT_PASS}" \
    -t test/ping -m "hello" -d
```

If `CONNACK (5)` (not authorised): Vault and Mosquitto are out of sync. Fix:

```bash
# Delete both, then regenerate together
kubectl delete secret mosquitto-passwd -n messaging

VAULT_TOKEN=$(cat ${POC_DIR}/vault/root-token)
docker run --rm --network host \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  -e VAULT_TOKEN="${VAULT_TOKEN}" \
  devops-toolkit:latest \
  vault kv metadata delete secret/apps/mqtt

bash ${POC_DIR}/scripts/messaging-init.sh

# Restart Mosquitto and sensor-dev pods
kubectl delete pod -n messaging -l app=mosquitto
kubectl delete pods -n sensor-dev --all
```

**If you see `Redis authentication failed`:** Same pattern — check and sync
`secret/apps/redis` vs `kubectl get secret redis-password -n messaging`.

**If you see `Kafka SASL authentication error`:** Check and sync
`secret/apps/kafka` vs the `user_sensor` password in `kafka-jaas` secret.

---

## Step 9 — Verify the full trace chain

Check mqtt-bridge and event-consumer are receiving and forwarding:

```bash
kubectl logs -n sensor-dev \
  $(kubectl get pod -n sensor-dev -l app=mqtt-bridge \
    -o jsonpath='{.items[0].metadata.name}') \
  -c mqtt-bridge --tail=10

kubectl logs -n sensor-dev \
  $(kubectl get pod -n sensor-dev -l app=event-consumer \
    -o jsonpath='{.items[0].metadata.name}') \
  -c event-consumer --tail=10
```

**Healthy mqtt-bridge output:**
```
info: BridgeWorker[0]  [trace:a1b2c3d4] Bridged sensorId=sensor-01 value=22.4 trend=rising
```

**Healthy event-consumer output:**
```
info: ConsumerWorker[0]  [trace:a1b2c3d4] Consumed event sensorId=sensor-01 value=22.4celsius trend=rising delta=+3.20
```

The trace ID `a1b2c3d4` should appear in both logs — that's the W3C trace context
propagated across MQTT and Kafka. One sensor reading, one trace ID, three services.

---

## Step 10 — Verify traces in Kibana

Open Kibana at `https://kibana.test` and go to **Discover**.

Select the `traces-generic.otel-default` data view from the index pattern dropdown.

Search for traces from the apps:
```
service.name : sensor-producer
```

Or search by a specific trace ID seen in the logs:
```
trace.id : a1b2c3d4*
```

You should see span documents with fields including:
- `service.name` — sensor-producer, mqtt-bridge, or event-consumer
- `trace.id` — the shared trace ID across all three services
- `span.name` — publish-sensor-reading, bridge-sensor-reading, consume-sensor-event
- `sensor.id`, `sensor.value`, `sensor.trend`, `sensor.delta` — custom span attributes

---

## Step 11 — GitOps demo sequence

This is the walkthrough for showing leadership the full platform in action.

**Setup:** Have Kibana Discover open on the `traces-generic.otel-default` data view,
and ArgoCD open at `https://argocd.test`.

**The demo:**

1. In Kibana, note the current event rate — one trace per second per sensor
2. Open `https://gitea.test/poc/sensor-demo-deploy`
3. Navigate to `base/configmap.yaml`
4. Click the pencil (edit) icon
5. Change `SENSOR_INTERVAL_MS: "1000"` to `SENSOR_INTERVAL_MS: "500"`
6. Commit directly to `main` with message `demo: increase sensor rate`
7. Switch to ArgoCD — watch `sensor-demo-dev` go OutOfSync then Synced (30-60 seconds)
8. Return to Kibana — event rate doubles. Same trace chain intact.

**What this demonstrates:**
- **GitOps:** a Git commit is the only way to change cluster state — no kubectl, no SSH
- **Observability:** the change is immediately measurable in Elasticsearch
- **Platform value:** CI/CD, secret management, and observability working together

---

## Troubleshooting reference

### Pods stuck in ImagePullBackOff

```bash
kubectl describe pod <pod-name> -n sensor-dev | grep -A5 "Events:"
```

If `no basic auth credentials`:
```bash
# Recreate pull secret
GITEA_PASS=$(gitea-token)
kubectl create secret docker-registry gitea-registry \
  -n sensor-dev \
  --docker-server=gitea.test \
  --docker-username=poc-admin \
  --docker-password="${GITEA_PASS}" \
  --dry-run=client -o yaml > /tmp/pull-secret.yaml
kubectl apply -f /tmp/pull-secret.yaml
kubectl delete pods -n sensor-dev --all
```

### ArgoCD stuck on Unknown sync status

ArgoCD repo server cannot reach Gitea. Check:
```bash
kubectl logs deployment/argocd-repo-server -n argocd --tail=20 | grep -i "error\|fail"
```

If `dial tcp 127.0.0.1:443: connect: connection refused`:
The ArgoCD credential secret has the wrong URL. Fix:
```bash
GITEA_PASS=$(gitea-token)
kubectl delete secret gitea-argocd-creds -n argocd
kubectl create secret generic gitea-argocd-creds -n argocd \
  --from-literal=username="poc-admin" \
  --from-literal=password="${GITEA_PASS}" \
  --from-literal=url="http://gitea-http.gitea.svc.cluster.local:3000/poc/sensor-demo-deploy"
kubectl label secret gitea-argocd-creds -n argocd \
  argocd.argoproj.io/secret-type=repository --overwrite
kubectl rollout restart deployment/argocd-repo-server -n argocd
```

### Gitea Actions workflow config file invalid

YAML parse error in workflow file. The most common cause is a `<<` in a `run:` block
which YAML interprets as a merge key. Check the workflow file for heredoc syntax and
replace with the base64 Python pattern used in `app-repos-init.sh`.

### Gitea Actions runner not picking up jobs

Check runner logs:
```bash
docker logs gitea-runner --tail=20
```

If `Cannot ping the Gitea instance server` with TLS error: CA cert not trusted.
Verify the runner was started with `-e CONFIG_FILE=/data/config.yml` and that
the config has the correct `options:` block with CA cert mount.

If runner is running but jobs don't trigger: push an empty commit to trigger:
```bash
cd ${POC_DIR}/apps/sensor-producer
git commit --allow-empty -m "ci: trigger build"
git push origin main
```

### Credentials out of sync after crash recovery

If apps are failing auth after a WSL restart or crash:

1. Bounce sensor-dev pods first — Vault Agent may have stale secrets:
   ```bash
   kubectl delete pods -n sensor-dev --all
   ```

2. If still failing, check what Vault has vs what the service expects (MQTT example):
   ```bash
   # What Vault has
   docker run --rm --network host \
     -e VAULT_ADDR=http://127.0.0.1:8200 \
     -e VAULT_TOKEN="$(cat ${POC_DIR}/vault/root-token)" \
     devops-toolkit:latest vault kv get secret/apps/mqtt

   # What Mosquitto has (the hash)
   kubectl get secret mosquitto-passwd -n messaging \
     -o jsonpath='{.data.passwd}' | base64 -d
   ```

3. If out of sync, delete both and regenerate:
   ```bash
   kubectl delete secret mosquitto-passwd -n messaging
   docker run --rm --network host \
     -e VAULT_ADDR=http://127.0.0.1:8200 \
     -e VAULT_TOKEN="$(cat ${POC_DIR}/vault/root-token)" \
     devops-toolkit:latest \
     vault kv metadata delete secret/apps/mqtt
   bash ${POC_DIR}/scripts/messaging-init.sh
   kubectl delete pod -n messaging -l app=mosquitto
   kubectl delete pods -n sensor-dev --all
   ```

### Test MQTT connectivity directly

```bash
MQTT_PASS=$(docker run --rm --network host \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  -e VAULT_TOKEN="$(cat ${POC_DIR}/vault/root-token)" \
  devops-toolkit:latest \
  vault kv get -field=password secret/apps/mqtt)

kubectl run mqtt-test --rm -it --restart=Never \
  -n messaging \
  --image=eclipse-mosquitto:2.0 \
  -- mosquitto_pub \
    -h mosquitto.messaging.svc.cluster.local \
    -p 1883 -u sensor -P "${MQTT_PASS}" \
    -t test/ping -m "hello" -d
```

`CONNACK (0)` = success. `CONNACK (5)` = wrong password.

---

## Adding a new service to the platform

This platform is designed to be extended. To add a fourth service (e.g. `alert-engine`):

**1. Create the app repo in Gitea:**
```bash
GITEA_PASS=$(gitea-token)
docker run --rm --network host devops-toolkit:latest \
  curl -sk -X POST \
  -u "poc-admin:${GITEA_PASS}" \
  -H "Content-Type: application/json" \
  "https://gitea.test/api/v1/orgs/poc/repos" \
  -d '{"name":"alert-engine","private":false,"auto_init":true,"default_branch":"main"}'
```

**2. Add the Vault auth role** in `vault-init.sh`:
```bash
vault write auth/kubernetes/role/alert-engine \
  bound_service_account_names=alert-engine \
  bound_service_account_namespaces=sensor-dev,sensor-qa,sensor-prod \
  policies=alert-engine-policy \
  ttl=1h
```

**3. Add base manifests** to `sensor-demo-deploy/base/`:
- `alert-engine.yaml` — Deployment with Vault annotations
- Add ServiceAccount to `serviceaccounts.yaml` with `imagePullSecrets`
- Add image placeholder to `alert-engine.yaml`: `image: alert-engine:latest`

**4. Add to the Kustomize image override** in `envs/dev/kustomization.yaml`:
```yaml
images:
  - name: alert-engine
    newName: gitea.test/poc/alert-engine
    newTag: latest   # CI will update this
```

**5. Copy the CI workflow** from any existing app and update `APP_NAME` and `IMAGE`.

**6. Push app source** — CI builds and deploys automatically.

---

## Promoting to QA and Production

`sensor-demo-qa` and `sensor-demo-prod` are set to manual sync in ArgoCD.
They watch the same deploy repo as dev but require explicit approval.

**To promote dev → QA:**
1. Open `https://argocd.test`
2. Click `sensor-demo-qa`
3. Click **Sync** → **Synchronize**
4. Pods start in `sensor-qa` with the same images as `sensor-dev`

**To promote QA → prod:** same process for `sensor-demo-prod`.

The gitea-registry pull secret is already in `sensor-qa` and `sensor-prod`
(created by `gitea-init.sh`). No additional setup needed for promotion.

---

## Session restart checklist

After a WSL restart or cluster restart, run in order:

```bash
# 1. Start the cluster
k3d cluster start poc

# 2. Start Elasticsearch port-forward in a dedicated terminal
pf-es

# 3. poc-start: unseals Vault, runs vault-init.sh, waits for ES, starts runner
poc-start

# 4. Verify sensor-dev pods are healthy
kubectl get pods -n sensor-dev

# 5. Check sensor-producer logs for active publishing
kubectl logs -n sensor-dev \
  $(kubectl get pod -n sensor-dev -l app=sensor-producer \
    -o jsonpath='{.items[0].metadata.name}') \
  -c sensor-producer --tail=5
```

If pods are 2/2 Running and logs show `Published sensorId=` with trace IDs, the
full pipeline is operational.
