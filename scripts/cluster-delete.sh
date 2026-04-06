#!/usr/bin/env bash
# scripts/cluster-delete.sh
# Deletes the k3d poc cluster and removes all state that would cause
# failures or confusion on the next fresh cluster build.
#
# What gets removed:
#   - k3d cluster 'poc' and all its containers/volumes
#   - vault/vault-init.json  (unseal key + root token for the deleted cluster)
#   - vault/root-token       (stale root token)
#   - kube/config            (stale kubeconfig — written as root, requires sudo)
#
# What is intentionally left alone:
#   - vault/poc-ca.key       (CA private key — persists across rebuilds by design)
#   - vault/poc-ca.crt       (CA cert — persists across rebuilds by design)
#   - helm-cache/            (reusable across rebuilds)
#   - tmp/                   (harmless)
#   - manifests/             (source files)
#   - apps/                  (source files)
#
# The CA files are generated once by generate-ca.sh and survive all cluster
# rebuilds. Only delete them manually if you need to rotate the CA.
#
# Usage:
#   bash scripts/cluster-delete.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[cluster-delete]${NC} $*"; }
warn() { echo -e "${YELLOW}[cluster-delete]${NC} $*"; }
step() { echo -e "\n${BLUE}── $* ──${NC}"; }

# ── Confirmation prompt ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${RED}This will permanently delete the k3d cluster 'poc' and its credentials.${NC}"
echo ""
echo "  The following will be removed:"
echo "    k3d cluster 'poc' (all containers and volumes)"
echo "    ${POC_DIR}/vault/vault-init.json"
echo "    ${POC_DIR}/vault/root-token"
echo "    ${POC_DIR}/kube/config"
echo ""
echo "  The following will be KEPT (CA persists across rebuilds):"
echo "    ${POC_DIR}/vault/poc-ca.key"
echo "    ${POC_DIR}/vault/poc-ca.crt"
echo ""
read -r -p "  Type 'yes' to confirm: " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
  echo "Aborted."
  exit 0
fi

# ── Delete k3d cluster ────────────────────────────────────────────────────────
step "Deleting k3d cluster"

# Mount the kube dir so k3d can clean up its kubeconfig entry cleanly.
# The WARN about /root/.kube/config is suppressed — we manage the kubeconfig
# ourselves and remove it explicitly below.
if docker run --rm \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${POC_DIR}/kube:/root/.kube" \
  devops-toolkit:latest \
  k3d cluster list 2>/dev/null | grep -q '^poc'; then
  docker run --rm \
    --network host \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${POC_DIR}/kube:/root/.kube" \
    devops-toolkit:latest \
    k3d cluster delete poc
  log "cluster 'poc' deleted"
else
  warn "cluster 'poc' not found — skipping k3d delete"
fi

# ── Remove stale Vault credentials ───────────────────────────────────────────
step "Removing stale Vault credentials"

# These files belong to the deleted cluster. Leaving them causes vault-init.sh
# and poc-start to fail with confusing errors on the next fresh build.
for f in \
  "${POC_DIR}/vault/vault-init.json" \
  "${POC_DIR}/vault/root-token"; do
  if [[ -f "${f}" ]]; then
    rm "${f}"
    log "removed ${f##*/}"
  else
    warn "${f##*/} not found — already clean"
  fi
done

# ── Remove stale kubeconfig ───────────────────────────────────────────────────
step "Removing stale kubeconfig"

# kube/config is written as root by the k3d merge step (runs inside a container).
# Remove it now so the next build starts clean. Requires sudo because of the
# root ownership. vault-init.sh recreates it correctly on the next build.
KUBECONFIG_FILE="${POC_DIR}/kube/config"
if [[ -f "${KUBECONFIG_FILE}" ]]; then
  sudo rm "${KUBECONFIG_FILE}"
  log "removed kube/config"
else
  warn "kube/config not found — already clean"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
log "cluster-delete.sh complete"
echo ""
echo "  Ready for a fresh build. Follow the rebuild runbook:"
echo "  documentation/rebuild-runbook.md"
echo ""
