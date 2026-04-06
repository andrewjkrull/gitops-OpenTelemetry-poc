#!/usr/bin/env bash
# scripts/coredns-patch.sh
# Patches CoreDNS to resolve gitea.test inside the cluster.
#
# Run this AFTER Traefik is installed and healthy (Step 8 in the runbook).
# Traefik must exist before this script runs — the rewrite rule points
# gitea.test at traefik.traefik.svc.cluster.local which must be resolvable.
#
# Why this is needed:
#   gitea.test is a browser-convenience hostname that resolves via /etc/hosts
#   on the server and workstation. Inside the cluster, nothing resolves it
#   by default. The Gitea Actions runner job containers need to reach
#   gitea.test for docker login, docker push, and git clone operations during CI.
#
#   We use a CoreDNS rewrite rule (not NodeHosts) because:
#   - rewrite rules live in the Corefile which survives node restarts
#   - NodeHosts is managed by the k3s addon reconciler and can be overwritten
#   - Pointing at the Traefik service DNS name is stable across rebuilds
#     (no hardcoded IPs that change between clusters)
#
# Safe to re-run — checks if the rewrite is already present before patching.
#
# Usage:
#   bash scripts/coredns-patch.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
NC='\033[0m'
log()  { echo -e "${GREEN}[coredns-patch]${NC} $*"; }
warn() { echo -e "${YELLOW}[coredns-patch]${NC} $*"; }
err()  { echo -e "${RED}[coredns-patch] ERROR:${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BLUE}── $* ──${NC}"; }

TOOLKIT_RUN="docker run --rm --network host
  -v ${POC_DIR}/kube:/root/.kube
  -e KUBECONFIG=/root/.kube/config
  devops-toolkit:latest"

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight"

# Traefik must be installed before this script runs
TRAEFIK_IP=$(${TOOLKIT_RUN} kubectl get svc traefik \
  -n traefik \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

if [[ -z "${TRAEFIK_IP}" ]]; then
  err "Traefik service not found in namespace traefik.
  Install Traefik first (Step 8 in the runbook), then re-run this script."
fi

log "Traefik service found — ClusterIP: ${TRAEFIK_IP}"

# ── Patch CoreDNS Corefile ────────────────────────────────────────────────────
step "Patching CoreDNS Corefile"

# Read current Corefile — strip \r in case of line ending issues
COREFILE=$(${TOOLKIT_RUN} kubectl get configmap coredns \
  -n kube-system \
  -o jsonpath='{.data.Corefile}' | tr -d '\r')

if echo "${COREFILE}" | grep -q "gitea.test"; then
  warn "gitea.test rewrite already present in CoreDNS Corefile — skipping"
else
  # Insert rewrite rule after the 'ready' line
  # rewrite name: resolves gitea.test as traefik.traefik.svc.cluster.local
  # which returns the Traefik ClusterIP — Traefik then routes by Host header
  NEW_COREFILE=$(echo "${COREFILE}" | sed \
    's|ready|ready\n    rewrite name gitea.test traefik.traefik.svc.cluster.local|')

  echo "${NEW_COREFILE}" > "${POC_DIR}/tmp/Corefile.txt"

  docker run --rm \
    --network host \
    -v "${POC_DIR}/kube:/root/.kube" \
    -v "${POC_DIR}/tmp:/tmp/poc" \
    -e KUBECONFIG=/root/.kube/config \
    devops-toolkit:latest \
    sh -c "kubectl create configmap coredns -n kube-system \
      --from-file=Corefile=/tmp/poc/Corefile.txt \
      --dry-run=client -o json > /tmp/poc/coredns-patch.json && \
      kubectl patch configmap coredns -n kube-system \
      --type=merge --patch-file=/tmp/poc/coredns-patch.json"

  rm -f "${POC_DIR}/tmp/Corefile.txt" "${POC_DIR}/tmp/coredns-patch.json"
  log "CoreDNS rewrite added — gitea.test → traefik.traefik.svc.cluster.local"
fi

# ── Restart CoreDNS ───────────────────────────────────────────────────────────
step "Restarting CoreDNS"

${TOOLKIT_RUN} kubectl rollout restart deployment/coredns -n kube-system
${TOOLKIT_RUN} kubectl rollout status deployment/coredns -n kube-system --timeout=60s
log "CoreDNS restarted and ready"

# ── Patch k3d node /etc/hosts ────────────────────────────────────────────────
step "Patching k3d node /etc/hosts"

# containerd on k3d nodes uses the node's /etc/hosts for DNS resolution when
# pulling images — it does not use cluster DNS. We must add gitea.test pointing
# at the Traefik ClusterIP so nodes can pull images tagged gitea.test/poc/<app>.
#
# This is ephemeral — lost on node restart. coredns-patch.sh must be re-run
# after any cluster restart (poc-start handles this via runner-start ordering).

for NODE in k3d-poc-server-0 k3d-poc-agent-0 k3d-poc-agent-1; do
  if docker exec "${NODE}" grep -q "gitea.test" /etc/hosts 2>/dev/null; then
    warn "${NODE}: gitea.test already in /etc/hosts — skipping"
  else
    docker exec "${NODE}" sh -c "echo '${TRAEFIK_IP} gitea.test' >> /etc/hosts"
    log "${NODE}: added gitea.test → ${TRAEFIK_IP}"
  fi
done

# ── Verify ────────────────────────────────────────────────────────────────────
step "Verifying"

log "Checking Corefile contains rewrite rule..."
${TOOLKIT_RUN} kubectl get configmap coredns -n kube-system \
  -o jsonpath='{.data.Corefile}' | grep "gitea.test" \
  && log "Rewrite rule confirmed" \
  || err "Rewrite rule not found — check CoreDNS configmap manually"

echo ""
log "coredns-patch.sh complete"
echo ""
echo "  gitea.test → traefik.traefik.svc.cluster.local (${TRAEFIK_IP})"
echo ""
echo "  Verify from inside the cluster:"
echo "    kubectl run dns-test --rm -it --restart=Never \\"
echo "      --image=busybox:1.36 -- nslookup gitea.test"
echo "    # Expected: Address: ${TRAEFIK_IP}"
echo ""
