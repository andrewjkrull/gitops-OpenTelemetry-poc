#!/usr/bin/env bash
# scripts/deploy-repo-init.sh
# Populates the sensor-demo-deploy repository in Gitea with the Kustomize
# overlay structure. Run once after Phase 4a — requires Gitea to be running
# and gitea-init.sh to have been run.
#
# What this does:
#   1. Clones sensor-demo-deploy from Gitea
#   2. Creates base/ and envs/dev,qa,prod/ with all Kustomize files
#   3. Pushes to main
#
# Prerequisites:
#   - Gitea running at https://gitea.test
#   - gitea-init.sh already run (repo exists)
#   - git configured on the host (git config user.email / user.name)
#
# Usage:
#   bash scripts/deploy-repo-init.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[deploy-repo-init]${NC} $*"; }
warn() { echo -e "${YELLOW}[deploy-repo-init]${NC} $*"; }
err()  { echo -e "${RED}[deploy-repo-init] ERROR:${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BLUE}── $* ──${NC}"; }

GITEA_URL="https://gitea.test"
GITEA_USER="poc-admin"
WORK_DIR="${POC_DIR}/tmp/deploy-repo-init"

# Read Gitea password from Kubernetes secret
GITEA_PASS=$(docker run --rm --network host \
  -v "${POC_DIR}/kube:/root/.kube" \
  -e KUBECONFIG=/root/.kube/config \
  devops-toolkit:latest \
  kubectl get secret gitea-admin-secret -n gitea \
  -o jsonpath='{.data.password}' | base64 -d | tr -d '\r\n')

if [[ -z "${GITEA_PASS}" ]]; then
  err "Could not read gitea-admin-secret. Is Gitea deployed?"
fi

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight"

# Verify git is configured
GIT_EMAIL=$(git config --global user.email 2>/dev/null || true)
GIT_NAME=$(git config --global user.name 2>/dev/null || true)

if [[ -z "${GIT_EMAIL}" || -z "${GIT_NAME}" ]]; then
  err "git user not configured. Run:
  git config --global user.email \"you@example.com\"
  git config --global user.name \"Your Name\""
fi
log "git user: ${GIT_NAME} <${GIT_EMAIL}>"

# Verify repo exists in Gitea
HTTP=$(docker run --rm --network host devops-toolkit:latest \
  curl -sk -o /dev/null -w "%{http_code}" \
  -u "${GITEA_USER}:${GITEA_PASS}" \
  "${GITEA_URL}/api/v1/repos/poc/sensor-demo-deploy")

if [[ "${HTTP}" != "200" ]]; then
  err "sensor-demo-deploy repo not found (HTTP ${HTTP}). Has gitea-init.sh been run?"
fi
log "sensor-demo-deploy repo found"

# ── Clone ─────────────────────────────────────────────────────────────────────
step "Clone"

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

# Embed credentials in clone URL — avoids interactive prompt
git clone \
  "https://${GITEA_USER}:${GITEA_PASS}@gitea.test/poc/sensor-demo-deploy.git" \
  "${WORK_DIR}/sensor-demo-deploy"

cd "${WORK_DIR}/sensor-demo-deploy"
log "cloned to ${WORK_DIR}/sensor-demo-deploy"

# ── Populate base/ ────────────────────────────────────────────────────────────
step "base/"

mkdir -p base

cat > base/kustomization.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - serviceaccounts.yaml
  - configmap.yaml
  - sensor-producer.yaml
  - mqtt-bridge.yaml
  - event-consumer.yaml
EOF

cat > base/configmap.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: sensor-config
data:
  # Sensor publishing interval in milliseconds.
  # Demo knob 1 — change and push to see ArgoCD sync the new rate into Kibana.
  SENSOR_INTERVAL_MS: "1000"

  # MQTT topic the sensor publishes to
  MQTT_TOPIC: "sensors/temperature"

  # Kafka topic the bridge forwards events to
  KAFKA_TOPIC: "sensor-events"

  # OTel collector endpoint
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector-gateway.observability.svc.cluster.local:4317"

  # Service name prefix — environment suffix appended by overlay
  SERVICE_NAME_PREFIX: "sensor-demo"
EOF

cat > base/serviceaccounts.yaml << 'EOF'
# ServiceAccounts for Vault Agent injection.
# Names must match bound_service_account_names in Vault auth roles exactly.
# imagePullSecrets references gitea-registry — created by gitea-init.sh
# in each sensor namespace so pods can pull from gitea.test registry.
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sensor-producer
imagePullSecrets:
  - name: gitea-registry
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mqtt-bridge
imagePullSecrets:
  - name: gitea-registry
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: event-consumer
imagePullSecrets:
  - name: gitea-registry
EOF

cat > base/sensor-producer.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sensor-producer
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sensor-producer
  template:
    metadata:
      labels:
        app: sensor-producer
      annotations:
        reloader.stakater.com/auto: "true"
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "sensor-producer"
        vault.hashicorp.com/agent-inject-secret-mqtt.env: "secret/data/apps/mqtt"
        vault.hashicorp.com/agent-inject-template-mqtt.env: |
          {{- with secret "secret/data/apps/mqtt" -}}
          MQTT_HOST={{ .Data.data.host }}
          MQTT_PORT={{ .Data.data.port }}
          MQTT_USERNAME={{ .Data.data.username }}
          MQTT_PASSWORD={{ .Data.data.password }}
          {{- end }}
        vault.hashicorp.com/agent-inject-secret-redis.env: "secret/data/apps/redis"
        vault.hashicorp.com/agent-inject-template-redis.env: |
          {{- with secret "secret/data/apps/redis" -}}
          REDIS_HOST={{ .Data.data.host }}
          REDIS_PORT={{ .Data.data.port }}
          REDIS_PASSWORD={{ .Data.data.password }}
          {{- end }}
    spec:
      serviceAccountName: sensor-producer
      containers:
        - name: sensor-producer
          image: sensor-producer
          envFrom:
            - configMapRef:
                name: sensor-config
          resources:
            requests:
              memory: "32Mi"
              cpu: "50m"
            limits:
              memory: "64Mi"
              cpu: "100m"
EOF

cat > base/mqtt-bridge.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mqtt-bridge
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mqtt-bridge
  template:
    metadata:
      labels:
        app: mqtt-bridge
      annotations:
        reloader.stakater.com/auto: "true"
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "mqtt-bridge"
        vault.hashicorp.com/agent-inject-secret-mqtt.env: "secret/data/apps/mqtt"
        vault.hashicorp.com/agent-inject-template-mqtt.env: |
          {{- with secret "secret/data/apps/mqtt" -}}
          MQTT_HOST={{ .Data.data.host }}
          MQTT_PORT={{ .Data.data.port }}
          MQTT_USERNAME={{ .Data.data.username }}
          MQTT_PASSWORD={{ .Data.data.password }}
          {{- end }}
        vault.hashicorp.com/agent-inject-secret-redis.env: "secret/data/apps/redis"
        vault.hashicorp.com/agent-inject-template-redis.env: |
          {{- with secret "secret/data/apps/redis" -}}
          REDIS_HOST={{ .Data.data.host }}
          REDIS_PORT={{ .Data.data.port }}
          REDIS_PASSWORD={{ .Data.data.password }}
          {{- end }}
        vault.hashicorp.com/agent-inject-secret-kafka.env: "secret/data/apps/kafka"
        vault.hashicorp.com/agent-inject-template-kafka.env: |
          {{- with secret "secret/data/apps/kafka" -}}
          KAFKA_BOOTSTRAP={{ .Data.data.bootstrap }}
          KAFKA_USERNAME={{ .Data.data.username }}
          KAFKA_PASSWORD={{ .Data.data.password }}
          KAFKA_SASL_MECHANISM={{ .Data.data.sasl_mechanism }}
          KAFKA_SECURITY_PROTOCOL={{ .Data.data.security_protocol }}
          {{- end }}
    spec:
      serviceAccountName: mqtt-bridge
      containers:
        - name: mqtt-bridge
          image: mqtt-bridge
          envFrom:
            - configMapRef:
                name: sensor-config
          resources:
            requests:
              memory: "32Mi"
              cpu: "50m"
            limits:
              memory: "64Mi"
              cpu: "100m"
EOF

cat > base/event-consumer.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: event-consumer
spec:
  replicas: 1
  selector:
    matchLabels:
      app: event-consumer
  template:
    metadata:
      labels:
        app: event-consumer
      annotations:
        reloader.stakater.com/auto: "true"
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "event-consumer"
        vault.hashicorp.com/agent-inject-secret-kafka.env: "secret/data/apps/kafka"
        vault.hashicorp.com/agent-inject-template-kafka.env: |
          {{- with secret "secret/data/apps/kafka" -}}
          KAFKA_BOOTSTRAP={{ .Data.data.bootstrap }}
          KAFKA_USERNAME={{ .Data.data.username }}
          KAFKA_PASSWORD={{ .Data.data.password }}
          KAFKA_SASL_MECHANISM={{ .Data.data.sasl_mechanism }}
          KAFKA_SECURITY_PROTOCOL={{ .Data.data.security_protocol }}
          {{- end }}
        vault.hashicorp.com/agent-inject-secret-redis.env: "secret/data/apps/redis"
        vault.hashicorp.com/agent-inject-template-redis.env: |
          {{- with secret "secret/data/apps/redis" -}}
          REDIS_HOST={{ .Data.data.host }}
          REDIS_PORT={{ .Data.data.port }}
          REDIS_PASSWORD={{ .Data.data.password }}
          {{- end }}
    spec:
      serviceAccountName: event-consumer
      containers:
        - name: event-consumer
          image: event-consumer
          envFrom:
            - configMapRef:
                name: sensor-config
          resources:
            requests:
              memory: "32Mi"
              cpu: "50m"
            limits:
              memory: "64Mi"
              cpu: "100m"
EOF

log "base/ files written"

# ── Populate envs/ ────────────────────────────────────────────────────────────
step "envs/"

for ENV in dev qa prod; do
  mkdir -p "envs/${ENV}"

  # dev overlay includes the BRIDGE_DELAY_MS demo knob patch.
  # qa and prod overlays do not — the latency injection key is dev-only.
  if [[ "${ENV}" == "dev" ]]; then
    cat > "envs/${ENV}/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: sensor-${ENV}

resources:
  - ../../base

images:
  # Phase 4b standin — maps app name to busybox so pods start immediately
  # CI (Phase 4c) overrides these with real image tags in envs/dev/kustomization.yaml
  - name: sensor-producer
    newName: busybox
    newTag: latest
  - name: mqtt-bridge
    newName: busybox
    newTag: latest
  - name: event-consumer
    newName: busybox
    newTag: latest

patches:
  - patch: |-
      - op: replace
        path: /data/SERVICE_NAME_PREFIX
        value: sensor-demo-${ENV}
      - op: add
        path: /data/BRIDGE_DELAY_MS
        value: "0"
    target:
      kind: ConfigMap
      name: sensor-config
EOF
  else
    cat > "envs/${ENV}/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: sensor-${ENV}

resources:
  - ../../base

images:
  # Phase 4b standin — maps app name to busybox so pods start immediately
  # CI (Phase 4c) overrides these with real image tags in envs/dev/kustomization.yaml
  - name: sensor-producer
    newName: busybox
    newTag: latest
  - name: mqtt-bridge
    newName: busybox
    newTag: latest
  - name: event-consumer
    newName: busybox
    newTag: latest

patches:
  - patch: |-
      - op: replace
        path: /data/SERVICE_NAME_PREFIX
        value: sensor-demo-${ENV}
    target:
      kind: ConfigMap
      name: sensor-config
EOF
  fi
  log "envs/${ENV}/kustomization.yaml written"
done

# ── Commit and push ───────────────────────────────────────────────────────────
step "Commit and push"

git add .
git status

git commit -m "feat: initial Kustomize overlay structure

- base/: shared manifests for sensor-producer, mqtt-bridge, event-consumer
- base/: ServiceAccounts for Vault Agent injection
- base/: ConfigMap with sensor configuration (demo knob: SENSOR_INTERVAL_MS)
- envs/dev: BRIDGE_DELAY_MS latency demo knob added via overlay patch (dev only)
- envs/dev,qa,prod: Kustomize overlays with namespace and image tag patches
- Phase 4b standin: busybox:latest — replaced with real images in Phase 4c"

git push origin main
log "pushed to ${GITEA_URL}/poc/sensor-demo-deploy"

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -rf "${WORK_DIR}"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
log "deploy-repo-init.sh complete"
echo ""
echo "  Repo: ${GITEA_URL}/poc/sensor-demo-deploy"
echo ""
echo "  Next: apply ArgoCD Applications"
echo "    kubectl apply -f /work/argocd-app-dev.yaml"
echo "    kubectl apply -f /work/argocd-app-qa.yaml"
echo "    kubectl apply -f /work/argocd-app-prod.yaml"
