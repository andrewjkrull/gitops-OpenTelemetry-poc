#!/usr/bin/env bash
# scripts/messaging-init.sh
# Generates and wires all credentials for the messaging layer.
# Run ONCE on fresh cluster build, BEFORE applying manifests/messaging.yaml.
# Idempotent: checks before creating — safe to re-run but only necessary once per cluster.
#
# What this script does:
#   1. Generates random passwords for MQTT (sensor user), Redis, Kafka (sensor user + admin)
#   2. Generates Mosquitto passwd file (htpasswd-style) using mosquitto_passwd in a container
#   3. Creates Kubernetes Secrets: mosquitto-passwd, redis-password, kafka-jaas
#   4. Writes Vault KV entries: secret/apps/mqtt, secret/apps/redis, secret/apps/kafka
#      (these are what Vault Agent injects into the app pods at runtime)
#
# Prerequisites:
#   - k3d cluster running
#   - Vault unsealed and vault-init.sh already run (Kubernetes auth configured)
#   - messaging namespace does NOT need to exist yet (created by messaging.yaml)
#   - Run from: ~/Projects/poc/
#
# Usage:
#   bash scripts/messaging-init.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[messaging-init]${NC} $*"; }
warn() { echo -e "${YELLOW}[messaging-init]${NC} $*"; }
err()  { echo -e "${RED}[messaging-init] ERROR:${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BLUE}── $* ──${NC}"; }

# ── Toolkit alias (matches poc-toolkit.zsh pattern) ───────────────────────────
TOOLKIT_RUN="docker run --rm \
  --network host \
  -v ${POC_DIR}/manifests:/work \
  -v ${POC_DIR}/kube:/root/.kube \
  -e KUBECONFIG=/root/.kube/config \
  devops-toolkit:latest"

# Vault CLI calls: NEVER mount vault dir (token helper conflict — see CONTEXT.md)
# Root token read directly from file; passed as env var.
VAULT_ROOT_TOKEN="$(cat "${POC_DIR}/vault/root-token" | tr -d '\r\n')"
VAULT_RUN="docker run --rm \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  -e VAULT_TOKEN=${VAULT_ROOT_TOKEN} \
  --network host \
  devops-toolkit:latest vault"

# ── Helpers ────────────────────────────────────────────────────────────────────
# Generate a random 32-char alphanumeric password (no special chars — safe for JAAS/redis-cli)
generate_password() {
  openssl rand -base64 32 | tr -d '/+=' | head -c 32
}

kubectl() {
  ${TOOLKIT_RUN} kubectl "$@"
}

vault_kv_exists() {
  # Check if a Vault KV key exists AND has non-destroyed data.
  # Uses metadata endpoint so soft-deleted keys are correctly detected as missing.
  local path="$1"
  local meta
  meta=$(${VAULT_RUN} kv metadata get -format=json "${path}" 2>/dev/null) || return 1
  # Check if the latest version is destroyed or deleted
  local destroyed deleted
  destroyed=$(echo "${meta}" | docker run --rm -i devops-toolkit:latest     jq -r '.data.versions | to_entries | sort_by(.key | tonumber) | last | .value.destroyed')
  deleted=$(echo "${meta}" | docker run --rm -i devops-toolkit:latest     jq -r '.data.versions | to_entries | sort_by(.key | tonumber) | last | .value.deletion_time')
  if [[ "${destroyed}" == "true" ]]; then return 1; fi
  if [[ "${deleted}" != "null" && -n "${deleted}" ]]; then return 1; fi
  return 0
}

# Check if both the Kubernetes secret AND Vault KV entry exist for a messaging credential.
# If they are out of sync, fail loudly rather than silently skipping.
check_credential_sync() {
  local ns="$1" secret_name="$2" vault_path="$3" label="$4"
  local k8s_exists vault_exists
  secret_exists "${ns}" "${secret_name}" && k8s_exists=true || k8s_exists=false
  vault_kv_exists "${vault_path}" && vault_exists=true || vault_exists=false

  if [[ "${k8s_exists}" == "true" && "${vault_exists}" == "true" ]]; then
    return 0  # both exist — skip
  elif [[ "${k8s_exists}" == "false" && "${vault_exists}" == "false" ]]; then
    return 1  # neither exists — create
  else
    # Out of sync — fail loudly
    err "${label} credentials are out of sync:
  Kubernetes secret '${secret_name}' in '${ns}': ${k8s_exists}
  Vault KV '${vault_path}': ${vault_exists}

  Fix by deleting whichever exists and re-running:
    kubectl delete secret ${secret_name} -n ${ns}   (if k8s exists)
    vault kv metadata delete ${vault_path}           (if vault exists)
  Then re-run messaging-init.sh"
  fi
}

secret_exists() {
  local ns="$1" name="$2"
  ${TOOLKIT_RUN} kubectl get secret "${name}" -n "${ns}" >/dev/null 2>&1
}

# ── Step 0: ensure messaging namespace exists ─────────────────────────────────
step "Namespace"
if ${TOOLKIT_RUN} kubectl get namespace messaging >/dev/null 2>&1; then
  warn "namespace 'messaging' already exists — skipping creation"
else
  log "creating namespace 'messaging'"
  ${TOOLKIT_RUN} kubectl create namespace messaging
fi

# ── Step 1: capture pre-creation state ───────────────────────────────────────
# Check sync state BEFORE creating anything — check_credential_sync must run
# against the state at script entry, not after K8s secrets have been created.
# If either side exists without the other at this point, that is genuine drift.
step "Pre-flight sync check"

MQTT_NEED_CREATE=false
REDIS_NEED_CREATE=false
KAFKA_NEED_CREATE=false

_mqtt_k8s=false;  secret_exists messaging mosquitto-passwd  && _mqtt_k8s=true  || true
_mqtt_vault=false; vault_kv_exists secret/apps/mqtt         && _mqtt_vault=true || true

_redis_k8s=false;  secret_exists messaging redis-password   && _redis_k8s=true  || true
_redis_vault=false; vault_kv_exists secret/apps/redis       && _redis_vault=true || true

_kafka_k8s=false;  secret_exists messaging kafka-jaas       && _kafka_k8s=true  || true
_kafka_vault=false; vault_kv_exists secret/apps/kafka       && _kafka_vault=true || true

# Fail loudly on drift (one side exists, other doesn't)
for _label in "MQTT:messaging:mosquitto-passwd:secret/apps/mqtt:${_mqtt_k8s}:${_mqtt_vault}" \
              "Redis:messaging:redis-password:secret/apps/redis:${_redis_k8s}:${_redis_vault}" \
              "Kafka:messaging:kafka-jaas:secret/apps/kafka:${_kafka_k8s}:${_kafka_vault}"; do
  IFS=: read -r _l _ns _sn _vp _ke _ve <<< "${_label}"
  if [[ "${_ke}" == "true" && "${_ve}" == "false" ]]; then
    err "${_l} credentials are out of sync:
  Kubernetes secret '${_sn}' in '${_ns}': true
  Vault KV '${_vp}': false

  Fix by deleting whichever exists and re-running:
    kubectl delete secret ${_sn} -n ${_ns}
    vault kv metadata delete ${_vp}
  Then re-run messaging-init.sh"
  elif [[ "${_ke}" == "false" && "${_ve}" == "true" ]]; then
    err "${_l} credentials are out of sync:
  Kubernetes secret '${_sn}' in '${_ns}': false
  Vault KV '${_vp}': true

  Fix by deleting whichever exists and re-running:
    kubectl delete secret ${_sn} -n ${_ns}
    vault kv metadata delete ${_vp}
  Then re-run messaging-init.sh"
  fi
done

# Determine what needs creating (both absent = needs create, both present = skip)
[[ "${_mqtt_k8s}"  == "false" && "${_mqtt_vault}"  == "false" ]] && MQTT_NEED_CREATE=true  || true
[[ "${_redis_k8s}" == "false" && "${_redis_vault}" == "false" ]] && REDIS_NEED_CREATE=true || true
[[ "${_kafka_k8s}" == "false" && "${_kafka_vault}" == "false" ]] && KAFKA_NEED_CREATE=true || true

log "sync check passed"
[[ "${MQTT_NEED_CREATE}"  == "false" ]] && warn "MQTT credentials already complete — will skip"
[[ "${REDIS_NEED_CREATE}" == "false" ]] && warn "Redis credentials already complete — will skip"
[[ "${KAFKA_NEED_CREATE}" == "false" ]] && warn "Kafka credentials already complete — will skip"

# ── Step 2: generate passwords ────────────────────────────────────────────────
step "Password generation"
log "generating credentials..."

MQTT_USER="sensor"
MQTT_PASS="$(generate_password)"

REDIS_PASS="$(generate_password)"

KAFKA_ADMIN_PASS="$(generate_password)"
KAFKA_SENSOR_USER="sensor"
KAFKA_SENSOR_PASS="$(generate_password)"

log "credentials generated (not printed — stored in Vault and Kubernetes Secrets)"

# ── Step 3: Mosquitto passwd file ─────────────────────────────────────────────
step "Mosquitto passwd Secret"
if [[ "${MQTT_NEED_CREATE}" == "false" ]]; then
  warn "Secret 'mosquitto-passwd' already exists — skipping"
else
  log "generating Mosquitto passwd file for user '${MQTT_USER}'..."

  # mosquitto_passwd -b writes: username:hash to stdout
  # We run it in the eclipse-mosquitto container (same version as deployed)
  PASSWD_CONTENT="$(docker run --rm eclipse-mosquitto:2.0 \
    sh -c "mosquitto_passwd -b /dev/stdout '${MQTT_USER}' '${MQTT_PASS}' 2>/dev/null || \
           mosquitto_passwd -c -b /tmp/p '${MQTT_USER}' '${MQTT_PASS}' && cat /tmp/p")"

  if [[ -z "${PASSWD_CONTENT}" ]]; then
    err "mosquitto_passwd produced no output — check Docker is running and eclipse-mosquitto:2.0 is accessible"
  fi

  # Write passwd to a temp file and use --from-file (inline doesn't work through toolkit — see CONTEXT.md)
  TMPDIR=$(mktemp -d)
  echo "${PASSWD_CONTENT}" > "${TMPDIR}/passwd"

  ${TOOLKIT_RUN} kubectl create secret generic mosquitto-passwd \
    -n messaging \
    --from-literal=passwd="${PASSWD_CONTENT}"

  rm -rf "${TMPDIR}"
  log "Secret 'mosquitto-passwd' created"
fi

# ── Step 4: Redis password Secret ─────────────────────────────────────────────
step "Redis password Secret"
if [[ "${REDIS_NEED_CREATE}" == "false" ]]; then
  warn "Secret 'redis-password' already exists — skipping"
else
  ${TOOLKIT_RUN} kubectl create secret generic redis-password \
    -n messaging \
    --from-literal=password="${REDIS_PASS}"
  log "Secret 'redis-password' created"
fi

# ── Step 5: Kafka JAAS Secret ─────────────────────────────────────────────────
step "Kafka JAAS Secret"
if [[ "${KAFKA_NEED_CREATE}" == "false" ]]; then
  warn "Secret 'kafka-jaas' already exists — skipping"
else
  JAAS_CONTENT="KafkaServer {
    org.apache.kafka.common.security.plain.PlainLoginModule required
    username=\"admin\"
    password=\"${KAFKA_ADMIN_PASS}\"
    user_admin=\"${KAFKA_ADMIN_PASS}\"
    user_${KAFKA_SENSOR_USER}=\"${KAFKA_SENSOR_PASS}\";
};

KafkaClient {
    org.apache.kafka.common.security.plain.PlainLoginModule required
    username=\"admin\"
    password=\"${KAFKA_ADMIN_PASS}\";
};"

  ${TOOLKIT_RUN} kubectl create secret generic kafka-jaas \
    -n messaging \
    --from-literal=kafka-jaas.conf="${JAAS_CONTENT}"
  log "Secret 'kafka-jaas' created"
fi

# ── Step 6: Vault KV — app secrets ────────────────────────────────────────────
# These are the secrets Vault Agent injects into the app pods at runtime.
# They match what the app reads from /vault/secrets/*.env
step "Vault KV — secret/apps/mqtt"
if [[ "${MQTT_NEED_CREATE}" == "false" ]]; then
  warn "secret/apps/mqtt already exists — skipping"
  warn "To update: delete both the k8s secret and vault kv entry then re-run"
else
  ${VAULT_RUN} kv put secret/apps/mqtt \
    host="mosquitto.messaging.svc.cluster.local" \
    port="1883" \
    username="${MQTT_USER}" \
    password="${MQTT_PASS}"
  # Show metadata to confirm write succeeded
  ${VAULT_RUN} kv get secret/apps/mqtt
  log "secret/apps/mqtt written"
fi

step "Vault KV — secret/apps/redis"
if [[ "${REDIS_NEED_CREATE}" == "false" ]]; then
  warn "secret/apps/redis already exists — skipping"
else
  ${VAULT_RUN} kv put secret/apps/redis \
    host="redis.messaging.svc.cluster.local" \
    port="6379" \
    password="${REDIS_PASS}"
  log "secret/apps/redis written"
fi

step "Vault KV — secret/apps/kafka"
if [[ "${KAFKA_NEED_CREATE}" == "false" ]]; then
  warn "secret/apps/kafka already exists — skipping"
else
  ${VAULT_RUN} kv put secret/apps/kafka \
    bootstrap="kafka.messaging.svc.cluster.local:9092" \
    username="${KAFKA_SENSOR_USER}" \
    password="${KAFKA_SENSOR_PASS}" \
    sasl_mechanism="PLAIN" \
    security_protocol="SASL_PLAINTEXT"
  log "secret/apps/kafka written"
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
log "messaging-init.sh complete"
echo ""
echo "  Kubernetes Secrets created:"
echo "    messaging/mosquitto-passwd"
echo "    messaging/redis-password"
echo "    messaging/kafka-jaas"
echo ""
echo "  Vault KV entries written:"
echo "    secret/apps/mqtt"
echo "    secret/apps/redis"
echo "    secret/apps/kafka"
echo ""
echo "  Next step: kubectl apply -f /work/messaging.yaml"
echo "  Then wait for pods:  kubectl get pods -n messaging -w"
