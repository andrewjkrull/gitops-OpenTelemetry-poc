#!/usr/bin/env bash
# scripts/cluster-create.sh
# Creates the k3d poc cluster with the pre-generated CA cert mounted into
# every node at creation time. Handles kubeconfig merge, address fix, and
# ownership fix automatically.
#
# Prerequisites:
#   - scripts/generate-ca.sh must have been run at least once on this machine
#   - No existing 'poc' cluster (run cluster-delete.sh first)
#
# What this does:
#   1. Verifies the CA cert exists (fails clearly if generate-ca.sh not run)
#   2. Creates the k3d cluster with all required port mappings and volume mounts
#   3. Merges the kubeconfig, fixes the 0.0.0.0 address, fixes ownership
#   4. Verifies all nodes are Ready
#
# Note: CoreDNS patching for gitea.test happens AFTER Traefik is installed.
#   Run scripts/coredns-patch.sh after Step 8 (Traefik) in the runbook.
#
# Usage:
#   bash scripts/cluster-create.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[cluster-create]${NC} $*"; }
warn() { echo -e "${YELLOW}[cluster-create]${NC} $*"; }
err()  { echo -e "${RED}[cluster-create] ERROR:${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BLUE}── $* ──${NC}"; }

CA_CERT="${POC_DIR}/vault/poc-ca.crt"
REGISTRIES_CONFIG="${POC_DIR}/k3d-registries.yaml"
KUBECONFIG_FILE="${POC_DIR}/kube/config"

# ── Preflight checks ──────────────────────────────────────────────────────────
step "Preflight"

# CA cert must exist — generated once by generate-ca.sh, persists across rebuilds
if [[ ! -f "${CA_CERT}" ]]; then
  err "CA cert not found at ${CA_CERT}
  Run first: bash ${POC_DIR}/scripts/generate-ca.sh"
fi
log "CA cert found: ${CA_CERT}"

# Registry config must exist
if [[ ! -f "${REGISTRIES_CONFIG}" ]]; then
  err "Registry config not found at ${REGISTRIES_CONFIG}"
fi
log "Registry config found: ${REGISTRIES_CONFIG}"

# Check no existing cluster
EXISTING=$(docker run --rm \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  devops-toolkit:latest \
  k3d cluster list 2>/dev/null | grep -c '^poc' || true)

if [[ "${EXISTING}" -gt 0 ]]; then
  err "Cluster 'poc' already exists.
  Run first: bash ${POC_DIR}/scripts/cluster-delete.sh"
fi
log "No existing cluster — proceeding"

# ── Create cluster ─────────────────────────────────────────────────────────────
step "Creating k3d cluster 'poc'"

# The CA cert is volume-mounted into every node at creation time.
# This means containerd trusts the Vault-issued certs from the moment the
# cluster starts — no post-creation injection needed.
#
# Note: k3d will warn "failed to stat file/directory" for the volume mounts
# because it runs inside a container and can't stat host paths. This is
# expected and harmless — the Docker daemon on the host can access the paths
# and the mounts succeed. The cluster will be created successfully.
docker run --rm \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  devops-toolkit:latest \
  k3d cluster create poc \
    --agents 2 \
    --k3s-arg "--disable=traefik@server:0" \
    --port "80:80@loadbalancer" \
    --port "443:443@loadbalancer" \
    --port "5000:30500@loadbalancer" \
    --volume "${REGISTRIES_CONFIG}:/etc/rancher/k3s/registries.yaml@all" \
    --volume "${CA_CERT}:/etc/ssl/certs/poc-ca.crt@all"

log "cluster created"

# ── Kubeconfig merge ──────────────────────────────────────────────────────────
step "Kubeconfig setup"

docker run --rm \
  --network host \
  -v "${POC_DIR}/kube:/root/.kube" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  devops-toolkit:latest \
  k3d kubeconfig merge poc --output /root/.kube/config
log "kubeconfig merged"

# Fix ownership — merge runs as root inside container
sudo chown "$(id -u):$(id -g)" "${KUBECONFIG_FILE}"
log "kubeconfig ownership fixed (${USER})"

# Fix 0.0.0.0 address — k3d writes this when merging from inside a container
sudo sed -i 's|server: https://0\.0\.0\.0:|server: https://127.0.0.1:|g' "${KUBECONFIG_FILE}"
log "kubeconfig server address normalised to 127.0.0.1"

# ── Verify nodes ──────────────────────────────────────────────────────────────
step "Waiting for nodes"

log "waiting for all nodes to be Ready..."
docker run --rm \
  --network host \
  -v "${POC_DIR}/kube:/root/.kube" \
  -e KUBECONFIG=/root/.kube/config \
  devops-toolkit:latest \
  kubectl wait node \
    --all \
    --for=condition=Ready \
    --timeout=120s
log "all nodes Ready"

# ── Verify CA cert in nodes ───────────────────────────────────────────────────
step "Verifying CA cert in nodes"

for NODE in k3d-poc-server-0 k3d-poc-agent-0 k3d-poc-agent-1; do
  if docker exec "${NODE}" test -f /etc/ssl/certs/poc-ca.crt 2>/dev/null; then
    log "  ${NODE}: poc-ca.crt present"
  else
    warn "  ${NODE}: poc-ca.crt NOT found — registry pulls may fail"
  fi
done

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
log "cluster-create.sh complete"
echo ""
echo "  Cluster: poc (1 server, 2 agents)"
echo "  Kubeconfig: ${KUBECONFIG_FILE}"
echo ""
echo "  Next steps (follow rebuild-runbook.md):"
echo "    1. Create and label namespaces"
echo "    2. Add Helm repositories"
echo "    3. helm upgrade --install vault ..."
echo "    4. bash ${POC_DIR}/scripts/vault-bootstrap.sh"
echo "    5. bash ${POC_DIR}/scripts/vault-init.sh"
echo "    ..."
echo "    After Traefik is healthy:"
echo "    bash ${POC_DIR}/scripts/coredns-patch.sh"
echo ""
