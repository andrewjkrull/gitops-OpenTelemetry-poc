#!/usr/bin/env bash
# scripts/vault-init.sh
# Idempotent Vault configuration — safe to run on every session start.
# Runs automatically via poc-start on every cluster restart.
#
# What this script configures:
#   - Kubeconfig synced to current cluster (self-healing)
#   - KV v2 secrets engine at secret/
#   - PKI: imports the pre-generated CA from poc-ca.crt/poc-ca.key,
#     creates intermediate CA, configures cert-manager role
#   - Kubernetes auth: always updates config (cluster CA changes after restarts)
#   - Vault policies and k8s auth roles for all apps
#     (bound to sensor-dev, sensor-qa, sensor-prod — all three environments)
#   - Elasticsearch password sync to Vault KV
#   - ArgoCD admin password sync to Vault KV
#   - Gitea admin password sync to Vault KV
#
# No Docker restarts. No CA cert export. No node injection.
# The CA is installed at cluster creation time by cluster-create.sh.
#
# Prerequisites:
#   - scripts/generate-ca.sh run at least once (provides poc-ca.crt + poc-ca.key)
#   - Vault unsealed and reachable at localhost:8200 (pf-vault running)
#   - k3d cluster 'poc' running
#
# Usage:
#   bash scripts/vault-init.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[vault-init]${NC} $*"; }
warn() { echo -e "${YELLOW}[vault-init]${NC} $*"; }
err()  { echo -e "${RED}[vault-init] ERROR:${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BLUE}── $* ──${NC}"; }

CA_CERT="${POC_DIR}/vault/poc-ca.crt"
CA_KEY="${POC_DIR}/vault/poc-ca.key"
VAULT_ROOT_TOKEN="$(cat "${POC_DIR}/vault/root-token" | tr -d '\r\n')"

# NEVER mount vault dir in docker run — token helper conflict.
# -i is required for policy writes that pipe content via heredoc into stdin.
VAULT_RUN="docker run --rm -i \
  --network host \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  -e VAULT_TOKEN=${VAULT_ROOT_TOKEN} \
  devops-toolkit:latest vault"

TOOLKIT_RUN="docker run --rm \
  --network host \
  -v ${POC_DIR}/manifests:/work \
  -v ${POC_DIR}/kube:/root/.kube \
  -e KUBECONFIG=/root/.kube/config \
  devops-toolkit:latest"

# ── Preflight ─────────────────────────────────────────────────────────────────
if [[ ! -f "${CA_CERT}" || ! -f "${CA_KEY}" ]]; then
  err "CA files not found — run scripts/generate-ca.sh first
  Expected:
    ${CA_CERT}
    ${CA_KEY}"
fi

# ── Vault reachability ────────────────────────────────────────────────────────
step "Vault connectivity"
if ! ${VAULT_RUN} status >/dev/null 2>&1; then
  err "Cannot reach Vault at localhost:8200. Is pf-vault running?"
fi
log "Vault is reachable"

# ── Kubeconfig sync ───────────────────────────────────────────────────────────
step "Kubeconfig sync"
docker run --rm \
  --network host \
  -v "${POC_DIR}/kube:/root/.kube" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  devops-toolkit:latest \
  k3d kubeconfig merge poc --output /root/.kube/config \
  && log "kubeconfig merged" \
  || warn "kubeconfig merge skipped — cluster may not exist yet"

KUBECONFIG_FILE="${POC_DIR}/kube/config"
if [[ -f "${KUBECONFIG_FILE}" ]]; then
  sudo chown "$(id -u):$(id -g)" "${KUBECONFIG_FILE}"
  sed -i 's|server: https://0\.0\.0\.0:|server: https://127.0.0.1:|g' "${KUBECONFIG_FILE}"
  log "kubeconfig ownership fixed, address normalised"
fi

# ── KV secrets engine ─────────────────────────────────────────────────────────
step "KV secrets engine"
if ${VAULT_RUN} secrets list | grep -q '^secret/'; then
  warn "KV already enabled — skipping"
else
  ${VAULT_RUN} secrets enable -path=secret kv-v2
  log "KV v2 enabled at secret/"
fi

# ── PKI ───────────────────────────────────────────────────────────────────────
step "PKI (intermediate CA)"
if ${VAULT_RUN} secrets list | grep -q '^pki_int/'; then
  warn "PKI already configured — skipping"
else
  log "configuring PKI with pre-generated CA..."

  ${VAULT_RUN} secrets enable -path=pki pki
  ${VAULT_RUN} secrets tune -max-lease-ttl=87600h pki

  cat "${CA_CERT}" "${CA_KEY}" | ${VAULT_RUN} write pki/config/ca pem_bundle=-
  log "root CA imported from poc-ca.crt + poc-ca.key"

  ${VAULT_RUN} secrets enable -path=pki_int pki
  ${VAULT_RUN} secrets tune -max-lease-ttl=43800h pki_int

  CSR=$(${VAULT_RUN} write -format=json pki_int/intermediate/generate/internal \
    common_name="poc-intermediate-ca" | jq -r '.data.csr')

  SIGNED=$(echo "${CSR}" | ${VAULT_RUN} write -format=json pki/root/sign-intermediate \
    csr=- format=pem_bundle ttl=43800h | jq -r '.data.certificate')

  echo "${SIGNED}" | ${VAULT_RUN} write pki_int/intermediate/set-signed certificate=-

  ${VAULT_RUN} write pki_int/config/urls \
    issuing_certificates="http://127.0.0.1:8200/v1/pki_int/ca" \
    crl_distribution_points="http://127.0.0.1:8200/v1/pki_int/crl"

  ${VAULT_RUN} write pki_int/roles/cert-manager \
    allowed_domains="test,svc.cluster.local" \
    allow_subdomains=true \
    allow_bare_domains=true \
    use_csr_common_name=true \
    use_csr_sans=true \
    require_cn=false \
    max_ttl=72h
  log "PKI configured"
fi

# ── Kubernetes auth ───────────────────────────────────────────────────────────
# Always update — must use the in-cluster Kubernetes API address, not the
# external kubeconfig address. Vault runs inside the cluster and needs to
# call back to the API server to validate service account tokens.
step "Kubernetes auth"
if ! ${VAULT_RUN} auth list | grep -q 'kubernetes/'; then
  log "enabling Kubernetes auth..."
  ${VAULT_RUN} auth enable kubernetes
fi

log "updating Kubernetes auth config..."
${VAULT_RUN} write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local:443" \
  disable_local_ca_jwt=false
log "Kubernetes auth configured"

# ── cert-manager role ─────────────────────────────────────────────────────────
step "cert-manager auth role"
if ${VAULT_RUN} read auth/kubernetes/role/cert-manager >/dev/null 2>&1; then
  warn "role 'cert-manager' already exists — skipping"
else
  ${VAULT_RUN} policy write cert-manager - <<'EOF'
path "pki_int/sign/cert-manager" {
  capabilities = ["create", "update"]
}
EOF
  ${VAULT_RUN} write auth/kubernetes/role/cert-manager \
    bound_service_account_names=cert-manager \
    bound_service_account_namespaces=cert-manager \
    policies=cert-manager \
    ttl=1h
  log "role 'cert-manager' created"
fi

# ── Phase 4: App policies ─────────────────────────────────────────────────────
step "Phase 4 — app policies"

if ! ${VAULT_RUN} policy read sensor-producer >/dev/null 2>&1; then
  log "creating policy: sensor-producer"
  ${VAULT_RUN} policy write sensor-producer - <<'EOF'
path "secret/data/apps/mqtt" {
  capabilities = ["read"]
}
path "secret/data/apps/redis" {
  capabilities = ["read"]
}
EOF
else
  warn "policy 'sensor-producer' already exists — skipping"
fi

if ! ${VAULT_RUN} policy read mqtt-bridge >/dev/null 2>&1; then
  log "creating policy: mqtt-bridge"
  ${VAULT_RUN} policy write mqtt-bridge - <<'EOF'
path "secret/data/apps/mqtt" {
  capabilities = ["read"]
}
path "secret/data/apps/redis" {
  capabilities = ["read"]
}
path "secret/data/apps/kafka" {
  capabilities = ["read"]
}
EOF
else
  warn "policy 'mqtt-bridge' already exists — skipping"
fi

if ! ${VAULT_RUN} policy read event-consumer >/dev/null 2>&1; then
  log "creating policy: event-consumer"
  ${VAULT_RUN} policy write event-consumer - <<'EOF'
path "secret/data/apps/kafka" {
  capabilities = ["read"]
}
path "secret/data/apps/redis" {
  capabilities = ["read"]
}
EOF
else
  warn "policy 'event-consumer' already exists — skipping"
fi

# ── Phase 4: Kubernetes auth roles ───────────────────────────────────────────
# Roles are bound to all three app namespaces (dev/qa/prod).
# This is idempotent — if roles already exist with the old 'apps' namespace
# binding, they are deleted and recreated with the correct namespaces.
step "Phase 4 — Kubernetes auth roles"

for ROLE in sensor-producer mqtt-bridge event-consumer; do
  POLICY="${ROLE}"
  # Capture vault output before piping to jq.
  # Prevents set -o pipefail from aborting when the role does not exist yet
  # (vault exits non-zero; separating the commands lets || true catch it cleanly).
  VAULT_OUT=$(${VAULT_RUN} read -format=json auth/kubernetes/role/${ROLE} 2>/dev/null || true)
  EXISTING_NS=$(echo "${VAULT_OUT}" | docker run --rm -i devops-toolkit:latest     jq -r '.data.bound_service_account_namespaces | join(",")' 2>/dev/null || echo "")

  # Recreate if missing or bound to old 'apps' namespace only
  if [[ -z "${EXISTING_NS}" ]] || [[ "${EXISTING_NS}" == "apps" ]]; then
    if [[ -n "${EXISTING_NS}" ]]; then
      log "role '${ROLE}' bound to old namespace '${EXISTING_NS}' — recreating"
      ${VAULT_RUN} delete auth/kubernetes/role/${ROLE} >/dev/null 2>&1 || true
    else
      log "creating k8s auth role: ${ROLE}"
    fi
    ${VAULT_RUN} write auth/kubernetes/role/${ROLE}       bound_service_account_names=${ROLE}       bound_service_account_namespaces=sensor-dev,sensor-qa,sensor-prod       policies=${POLICY}       ttl=1h
    log "role '${ROLE}' created (namespaces: sensor-dev, sensor-qa, sensor-prod)"
  else
    warn "role '${ROLE}' already exists with namespaces '${EXISTING_NS}' — skipping"
  fi
done

# ── ES password sync ──────────────────────────────────────────────────────────
step "Elasticsearch password sync"
ES_PASS=$(docker run --rm \
  --network host \
  -v "${POC_DIR}/kube:/root/.kube" \
  -e KUBECONFIG=/root/.kube/config \
  devops-toolkit:latest \
  kubectl get secret elasticsearch-es-elastic-user \
  -n observability -o jsonpath='{.data.elastic}' 2>/dev/null \
  | base64 -d | tr -d '\r\n' || true)

if [[ -n "${ES_PASS}" ]]; then
  ${VAULT_RUN} kv put secret/observability/elasticsearch password="${ES_PASS}"
  log "ES password synced to Vault"
else
  warn "Elasticsearch secret not found — skipping (normal if ES not yet deployed)"
fi

# ── ArgoCD password sync ─────────────────────────────────────────────────────
step "ArgoCD password sync"
ARGOCD_PASS=$(docker run --rm \
  --network host \
  -v "${POC_DIR}/kube:/root/.kube" \
  -e KUBECONFIG=/root/.kube/config \
  devops-toolkit:latest \
  kubectl get secret argocd-initial-admin-secret \
  -n argocd -o jsonpath='{.data.password}' 2>/dev/null \
  | base64 -d | tr -d '\r\n' || true)

if [[ -n "${ARGOCD_PASS}" ]]; then
  ${VAULT_RUN} kv put secret/argocd/admin password="${ARGOCD_PASS}"
  log "ArgoCD password synced to Vault"
else
  warn "ArgoCD secret not found — skipping (normal if ArgoCD not yet deployed)"
fi

# ── Gitea admin password sync ─────────────────────────────────────────────────
step "Gitea admin password sync"
GITEA_PASS=$(docker run --rm \
  --network host \
  -v "${POC_DIR}/kube:/root/.kube" \
  -e KUBECONFIG=/root/.kube/config \
  devops-toolkit:latest \
  kubectl get secret gitea-admin-secret \
  -n gitea -o jsonpath='{.data.password}' 2>/dev/null \
  | base64 -d | tr -d '\r\n' || true)

if [[ -n "${GITEA_PASS}" ]]; then
  ${VAULT_RUN} kv put secret/gitea/admin password="${GITEA_PASS}"
  log "Gitea password synced to Vault"
else
  warn "Gitea secret not found — skipping (normal if Gitea not yet deployed)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
log "vault-init.sh complete"
