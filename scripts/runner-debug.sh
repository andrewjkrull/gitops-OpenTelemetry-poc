#!/usr/bin/env bash
# scripts/runner-debug.sh
# Tests all assumptions for running the Gitea Actions runner on the Linux host.
# Run this BEFORE setting up the host runner to verify everything is in place.
#
# Usage: bash scripts/runner-debug.sh

set -uo pipefail

POC_DIR="${HOME}/Projects/poc"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
pass() { echo -e "${GREEN}  ✓${NC} $*"; }
fail() { echo -e "${RED}  ✗${NC} $*"; }
warn() { echo -e "${YELLOW}  !${NC} $*"; }
step() { echo -e "\n${BLUE}── $* ──${NC}"; }

ERRORS=0
err() { fail "$*"; ERRORS=$((ERRORS + 1)); }

echo ""
echo "Gitea Actions Runner — Host Environment Debug"
echo "=============================================="

# ── Docker ────────────────────────────────────────────────────────────────────
step "Docker"

if docker info > /dev/null 2>&1; then
  pass "Docker daemon reachable"
  pass "Docker socket: $(ls -la /var/run/docker.sock | awk '{print $NF, $1, $3, $4}')"
else
  err "Docker daemon not reachable"
fi

DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
pass "Docker server version: ${DOCKER_VERSION}"

# ── Internet access ───────────────────────────────────────────────────────────
step "Internet access (from host)"

if curl -sk --max-time 5 https://api.nuget.org/v3/index.json > /dev/null 2>&1; then
  pass "NuGet (api.nuget.org) reachable"
else
  err "NuGet (api.nuget.org) NOT reachable"
fi

if curl -sk --max-time 5 https://mcr.microsoft.com/v2/ > /dev/null 2>&1; then
  pass "MCR (mcr.microsoft.com) reachable"
else
  err "MCR (mcr.microsoft.com) NOT reachable"
fi

if curl -sk --max-time 5 https://gcr.io/v2/ > /dev/null 2>&1; then
  pass "GCR (gcr.io) reachable"
else
  err "GCR (gcr.io) NOT reachable"
fi

# ── DNS and hosts ─────────────────────────────────────────────────────────────
step "DNS and /etc/hosts"

HOST_NS=$(grep "^nameserver" /etc/resolv.conf | head -2 | awk '{print $2}' | tr '\n' ' ')
pass "Host nameservers: ${HOST_NS}"

if grep -q "gitea.test" /etc/hosts; then
  pass "/etc/hosts: $(grep 'gitea.test' /etc/hosts)"
else
  err "gitea.test not in /etc/hosts"
fi

# ── gitea.test connectivity ───────────────────────────────────────────────────
step "gitea.test via Traefik"

GITEA_TEST=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" \
  https://gitea.test 2>/dev/null || echo "000")
if [[ "${GITEA_TEST}" == "200" ]]; then
  pass "https://gitea.test → ${GITEA_TEST}"
else
  err "https://gitea.test → ${GITEA_TEST}"
fi

# Test registry endpoint specifically
REGISTRY_STATUS=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" \
  https://gitea.test/v2/ 2>/dev/null || echo "000")
pass "https://gitea.test/v2/ (registry) → ${REGISTRY_STATUS}"

# ── CA certificate ────────────────────────────────────────────────────────────
step "CA certificate"

if [[ -f "${POC_DIR}/vault/poc-ca.crt" ]]; then
  pass "poc-ca.crt found"
else
  err "poc-ca.crt NOT found at ${POC_DIR}/vault/poc-ca.crt"
fi

if curl -s --max-time 5 https://gitea.test > /dev/null 2>&1; then
  pass "CA cert trusted by host curl"
else
  warn "CA cert may not be in host trust store"
fi

# ── Docker container simulation ───────────────────────────────────────────────
step "Job container simulation (host network + /etc/hosts mount)"

echo "  Testing with host DNS + /etc/hosts mount (how runner job containers run)..."
docker run --rm \
  --network host \
  -v /etc/hosts:/etc/hosts:ro \
  -v "${POC_DIR}/vault/poc-ca.crt:/usr/local/share/ca-certificates/poc-ca.crt:ro" \
  -e SSL_CERT_DIR=/usr/local/share/ca-certificates \
  alpine sh -c '
    update-ca-certificates > /dev/null 2>&1 || true
    echo "--- DNS resolv.conf ---"
    cat /etc/resolv.conf | grep -v "^#" | grep -v "^$"
    echo ""
    echo "--- NuGet internet ---"
    wget -qO- --timeout=10 https://api.nuget.org/v3/index.json > /dev/null 2>&1 \
      && echo "OK" || echo "FAILED"
    echo "--- MCR internet ---"
    wget -qO- --timeout=10 https://mcr.microsoft.com/v2/ > /dev/null 2>&1 \
      && echo "OK" || echo "FAILED"
    echo "--- gitea.test (via hosts file) ---"
    wget -qO- --timeout=5 --ca-certificate=/usr/local/share/ca-certificates/poc-ca.crt \
      https://gitea.test > /dev/null 2>&1 \
      && echo "OK" || echo "FAILED"
    echo "--- gitea.test registry endpoint ---"
    wget -qO- --timeout=5 --ca-certificate=/usr/local/share/ca-certificates/poc-ca.crt \
      https://gitea.test/v2/ > /dev/null 2>&1 \
      && echo "OK" || echo "FAILED"
  ' 2>/dev/null \
  && pass "Container simulation complete" \
  || err "Container simulation failed"

# ── Kaniko ────────────────────────────────────────────────────────────────────
step "Kaniko"

if docker image inspect gcr.io/kaniko-project/executor:latest > /dev/null 2>&1; then
  pass "gcr.io/kaniko-project/executor:latest already present"
else
  echo "  Pulling Kaniko executor..."
  if docker pull gcr.io/kaniko-project/executor:latest > /dev/null 2>&1; then
    pass "gcr.io/kaniko-project/executor:latest pulled successfully"
  else
    err "Could not pull Kaniko executor"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
if [[ ${ERRORS} -eq 0 ]]; then
  echo -e "${GREEN}All checks passed — host runner should work correctly${NC}"
else
  echo -e "${RED}${ERRORS} check(s) failed — resolve issues above before starting runner${NC}"
fi
echo "══════════════════════════════════════════"
echo ""
