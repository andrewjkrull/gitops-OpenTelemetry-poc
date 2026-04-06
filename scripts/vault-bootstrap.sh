#!/usr/bin/env bash
# vault-bootstrap.sh — run ONCE on a fresh cluster to initialize Vault
#
# Prerequisites:
#   - pf-vault running in a dedicated terminal
#   - Vault pod Running (1/1) — confirmed via: kubectl get pods -n vault
#
# What this does:
#   1. Runs vault operator init (1 key share, threshold 1)
#   2. Saves vault-init.json + root-token to ${POC_DIR}/vault/
#   3. Creates vault-unseal-secret Kubernetes Secret with the unseal key
#   4. Unseals Vault via port-forward
#   5. Verifies Vault is unsealed
#
# After this script:
#   - Run vault-init.sh to configure PKI, K8s auth, KV
#   - On all future restarts, poc-start unseals via port-forward
#   - Never run this script again unless you wipe the cluster

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_ADDR

VAULT_DIR="${POC_DIR}/vault"
INIT_JSON="${VAULT_DIR}/vault-init.json"
ROOT_TOKEN_FILE="${VAULT_DIR}/root-token"
TOOLKIT_IMAGE="${TOOLKIT_IMAGE:-devops-toolkit:latest}"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
echo "==> Preflight..."

mkdir -p "${VAULT_DIR}"
chmod 700 "${VAULT_DIR}"

if [[ -f "${INIT_JSON}" ]]; then
  echo ""
  echo "ERROR: ${INIT_JSON} already exists."
  echo "Vault appears to have been initialized previously."
  echo "If this is a genuine fresh cluster, remove the stale files:"
  echo "  rm ${INIT_JSON} ${ROOT_TOKEN_FILE}"
  exit 1
fi

HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${VAULT_ADDR}/v1/sys/health" 2>/dev/null || echo "000")
if [[ "${HTTP}" == "000" ]]; then
  echo "ERROR: Cannot reach ${VAULT_ADDR} — is pf-vault running?"
  exit 1
fi
echo "    Vault API responding (HTTP ${HTTP})."

if [[ "${HTTP}" != "501" ]]; then
  echo "ERROR: Expected HTTP 501 (uninitialized) but got ${HTTP}."
  echo "If 200/503 — Vault may already be initialized. Check vault status."
  exit 1
fi

# ---------------------------------------------------------------------------
# vault operator init
# Run via docker directly — no VAULT_MOUNT to avoid token helper conflict
# with /root/.vault being a directory. Output captured on host via redirect.
# ---------------------------------------------------------------------------
echo ""
echo "==> Running vault operator init..."

docker run --rm --network host \
  -e VAULT_ADDR="${VAULT_ADDR}" \
  -e VAULT_TOKEN="init-no-token-needed" \
  ${TOOLKIT_IMAGE} \
  vault operator init -key-shares=1 -key-threshold=1 -format=json \
  > "${INIT_JSON}"

if [[ ! -s "${INIT_JSON}" ]]; then
  echo "ERROR: vault-init.json is empty — operator init may have failed."
  exit 1
fi

chmod 600 "${INIT_JSON}"
echo "    Saved: ${INIT_JSON}"

UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' "${INIT_JSON}")
ROOT_TOKEN=$(jq -r '.root_token' "${INIT_JSON}")

if [[ -z "${UNSEAL_KEY}" || "${UNSEAL_KEY}" == "null" ]]; then
  echo "ERROR: Could not extract unseal key from ${INIT_JSON}"
  cat "${INIT_JSON}"
  exit 1
fi

printf '%s' "${ROOT_TOKEN}" > "${ROOT_TOKEN_FILE}"
chmod 600 "${ROOT_TOKEN_FILE}"
echo "    Saved: ${ROOT_TOKEN_FILE}"

# ---------------------------------------------------------------------------
# Store unseal key in Kubernetes Secret
# ---------------------------------------------------------------------------
echo ""
echo "==> Storing unseal key in vault-unseal-secret..."

docker run --rm --network host \
  -v "${POC_DIR}/kube:/root/.kube" \
  -e KUBECONFIG=/root/.kube/config \
  ${TOOLKIT_IMAGE} \
  kubectl create secret generic vault-unseal-secret \
    --namespace vault \
    --from-literal=key="${UNSEAL_KEY}" \
    --dry-run=client -o yaml \
| docker run --rm -i --network host \
  -v "${POC_DIR}/kube:/root/.kube" \
  -e KUBECONFIG=/root/.kube/config \
  ${TOOLKIT_IMAGE} \
  kubectl apply -f -

echo "    Secret created."

# ---------------------------------------------------------------------------
# Unseal Vault via port-forward
# ---------------------------------------------------------------------------
echo ""
echo "==> Unsealing Vault..."

docker run --rm --network host \
  -e VAULT_ADDR="${VAULT_ADDR}" \
  -e VAULT_TOKEN="unseal-no-token-needed" \
  ${TOOLKIT_IMAGE} \
  vault operator unseal "${UNSEAL_KEY}"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo ""
echo "==> Verifying..."

SEALED=$(docker run --rm --network host \
  -e VAULT_ADDR="${VAULT_ADDR}" \
  -e VAULT_TOKEN="${ROOT_TOKEN}" \
  ${TOOLKIT_IMAGE} \
  vault status -format=json 2>/dev/null \
  | jq -r '.sealed')

if [[ "${SEALED}" == "false" ]]; then
  echo "    Vault is initialized and unsealed."
else
  echo "ERROR: Vault sealed=${SEALED} — check: vault status"
  exit 1
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  vault-bootstrap.sh complete"
echo "============================================================"
echo ""
echo "  Init data:   ${INIT_JSON}"
echo "  Root token:  ${ROOT_TOKEN_FILE}"
echo ""
echo "  Next: run vault-init.sh"
echo "    bash ${POC_DIR}/scripts/vault-init.sh"
echo "============================================================"
