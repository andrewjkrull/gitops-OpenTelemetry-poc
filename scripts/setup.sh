#!/usr/bin/env bash
# scripts/setup.sh
# First-time environment setup for the Kubernetes PoC.
# Safe to re-run — checks before changing anything.
#
# What this script does:
#   1. Checks zsh is installed (required — poc-toolkit.zsh is zsh-only)
#   2. Copies poc-toolkit.zsh to ~/.zshrc.d/
#   3. Sets POC_DIR and TOOLKIT_DIR to match this machine's layout
#   4. Wires up sourcing in ~/.zshrc
#   5. Creates the runtime directory structure
#   6. Checks the devops-toolkit image is present
#   7. Prints a clear summary of what to do next
#
# Usage:
#   bash scripts/setup.sh
#
# Run from the root of the poc repo:
#   cd ~/wherever/poc && bash scripts/setup.sh

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[setup]${NC} $*"; }
err()  { echo -e "${RED}[setup] ERROR:${NC} $*" >&2; }
step() { echo -e "\n${BLUE}${BOLD}── $* ──${NC}"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; }

# ── Derive poc repo root from script location ─────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo ""
echo -e "${BOLD}Kubernetes PoC — Environment Setup${NC}"
echo "─────────────────────────────────────────"
echo "Repo root: ${POC_REPO}"
echo ""

# ── Step 1: Check zsh is installed ───────────────────────────────────────────
step "Checking prerequisites"

if ! command -v zsh >/dev/null 2>&1; then
  fail "zsh is not installed"
  echo ""
  echo "  The toolkit shell environment (poc-toolkit.zsh) requires zsh."
  echo "  Install it for your platform:"
  echo ""
  echo "    Debian/Ubuntu:  sudo apt-get install -y zsh"
  echo "    Fedora/RHEL:    sudo dnf install -y zsh"
  echo "    macOS:          zsh ships by default — check your PATH"
  echo ""
  echo "  After installing zsh, re-run this script."
  exit 1
fi
ok "zsh found at $(command -v zsh) ($(zsh --version | head -1))"

if ! command -v docker >/dev/null 2>&1; then
  fail "docker is not installed or not in PATH"
  echo ""
  echo "  Docker Engine must be running before the toolkit will work."
  echo "  On WSL2: install Docker Engine natively inside WSL2 (not Docker Desktop)."
  echo ""
  echo "    curl -fsSL https://get.docker.com | sh"
  echo ""
  exit 1
fi
ok "docker binary found ($(docker --version))"

# Check the daemon is actually reachable by this user
# 'docker info' talks to the daemon — catches both 'daemon not running'
# and 'permission denied' (user not in docker group)
if ! docker info >/dev/null 2>&1; then
  DOCKER_INFO_ERR="$(docker info 2>&1 || true)"
  fail "docker daemon is not accessible"
  echo ""
  if echo "${DOCKER_INFO_ERR}" | grep -qi "permission denied"; then
    echo "  Your user does not have permission to talk to the Docker daemon."
    echo "  Add yourself to the docker group:"
    echo ""
    echo "    sudo usermod -aG docker \${USER}"
    echo "    newgrp docker"
    echo ""
    echo "  Then re-run this script. You may need to log out and back in"
    echo "  for the group change to take full effect."
  elif echo "${DOCKER_INFO_ERR}" | grep -qi "cannot connect\|no such file\|not found"; then
    echo "  The Docker daemon is not running."
    echo "  Start it:"
    echo ""
    echo "    sudo service docker start"
    echo "    # or on systemd: sudo systemctl start docker"
    echo ""
  else
    echo "  Unexpected error contacting the Docker daemon:"
    echo "    ${DOCKER_INFO_ERR}" | head -3
    echo ""
  fi
  exit 1
fi
ok "docker daemon accessible"

# ── Step 2: Determine POC_DIR and TOOLKIT_DIR ─────────────────────────────────
step "Configuring paths"

echo "  This script detected the poc repo at:"
echo "    ${POC_REPO}"
echo ""

# Default TOOLKIT_DIR — guess based on poc repo sibling
DEFAULT_TOOLKIT_DIR="$(dirname "${POC_REPO}")/docker-devops"

echo "  Two variables need to be set in poc-toolkit.zsh:"
echo ""
echo "    POC_DIR     — path to this repo (auto-detected)"
echo "    TOOLKIT_DIR — path to the docker-devops repo"
echo ""

# Prompt for confirmation / override of POC_DIR
read -r -p "  POC_DIR [${POC_REPO}]: " INPUT_POC_DIR
FINAL_POC_DIR="${INPUT_POC_DIR:-${POC_REPO}}"

# Prompt for TOOLKIT_DIR
read -r -p "  TOOLKIT_DIR [${DEFAULT_TOOLKIT_DIR}]: " INPUT_TOOLKIT_DIR
FINAL_TOOLKIT_DIR="${INPUT_TOOLKIT_DIR:-${DEFAULT_TOOLKIT_DIR}}"

echo ""
log "Using POC_DIR:     ${FINAL_POC_DIR}"
log "Using TOOLKIT_DIR: ${FINAL_TOOLKIT_DIR}"

# ── Step 3: Copy and configure poc-toolkit.zsh ───────────────────────────────
step "Installing shell environment"

TOOLKIT_SRC="${POC_REPO}/documentation/poc-toolkit.zsh"
TOOLKIT_DEST="${HOME}/.zshrc.d/poc-toolkit.zsh"

if [[ ! -f "${TOOLKIT_SRC}" ]]; then
  err "poc-toolkit.zsh not found at ${TOOLKIT_SRC}"
  echo "  Make sure you are running this script from the poc repo root."
  exit 1
fi

mkdir -p "${HOME}/.zshrc.d"

# Copy the file
cp "${TOOLKIT_SRC}" "${TOOLKIT_DEST}"
ok "Copied poc-toolkit.zsh to ${TOOLKIT_DEST}"

# Patch POC_DIR in the copied file
sed -i "s|^export POC_DIR=.*|export POC_DIR=\"${FINAL_POC_DIR}\"|" "${TOOLKIT_DEST}"
ok "Set POC_DIR=${FINAL_POC_DIR}"

# Patch TOOLKIT_DIR in the copied file
sed -i "s|^export TOOLKIT_DIR=.*|export TOOLKIT_DIR=\"${FINAL_TOOLKIT_DIR}\"|" "${TOOLKIT_DEST}"
ok "Set TOOLKIT_DIR=${FINAL_TOOLKIT_DIR}"

# ── Step 4: Wire up sourcing in ~/.zshrc ──────────────────────────────────────
step "Configuring ~/.zshrc"

ZSHRC="${HOME}/.zshrc"
SOURCE_LINE='for f in ~/.zshrc.d/*.zsh; do source "$f"; done'

if grep -q 'zshrc.d' "${ZSHRC}" 2>/dev/null; then
  warn "~/.zshrc already sources ~/.zshrc.d/ — skipping"
else
  echo "" >> "${ZSHRC}"
  echo "# PoC toolkit environment" >> "${ZSHRC}"
  echo "${SOURCE_LINE}" >> "${ZSHRC}"
  ok "Added sourcing line to ~/.zshrc"
fi

# ── Step 5: Create runtime directories ───────────────────────────────────────
step "Creating runtime directories"

for dir in manifests tmp kube helm-cache helm-config vault documentation scripts apps; do
  mkdir -p "${FINAL_POC_DIR}/${dir}"
done
ok "Runtime directories ready under ${FINAL_POC_DIR}/"

# ── Step 6: Check toolkit image ───────────────────────────────────────────────
step "Checking devops-toolkit image"

if docker image inspect devops-toolkit:latest >/dev/null 2>&1; then
  ok "devops-toolkit:latest is present"
else
  warn "devops-toolkit:latest not found"
  echo ""
  echo "  Build it from the docker-devops repo:"
  echo ""
  if [[ -d "${FINAL_TOOLKIT_DIR}" ]]; then
    echo "    cd \"${FINAL_TOOLKIT_DIR}\" && make build"
  else
    echo "    The docker-devops repo was not found at: ${FINAL_TOOLKIT_DIR}"
    echo "    Clone it, then run: cd <docker-devops-path> && make build"
  fi
  echo ""
  echo "  The toolkit image must be built before any poc commands will work."
  echo "  You can continue setup now and build the image separately."
fi

# ── Step 7: Check /etc/hosts ──────────────────────────────────────────────────
step "Checking /etc/hosts entries"

HOSTS_NEEDED=(whoami.test httpbin.test traefik.test kibana.test gitea.test argocd.test)
HOSTS_MISSING=()

for host in "${HOSTS_NEEDED[@]}"; do
  if grep -q "${host}" /etc/hosts 2>/dev/null; then
    ok "${host}"
  else
    fail "${host} — missing"
    HOSTS_MISSING+=("${host}")
  fi
done

if [[ ${#HOSTS_MISSING[@]} -gt 0 ]]; then
  echo ""
  warn "Add the missing entries to /etc/hosts:"
  echo ""
  echo "  sudo tee -a /etc/hosts <<EOF"
  for host in "${HOSTS_MISSING[@]}"; do
    echo "  127.0.0.1  ${host}"
  done
  echo "  EOF"
  echo ""
  warn "If accessing from a Windows browser, also add them to:"
  echo "  C:\\Windows\\System32\\drivers\\etc\\hosts"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo -e "${BOLD}Setup complete.${NC}"
echo ""
echo "Next steps:"
echo ""
echo "  1. Reload your shell:"
echo "       source ~/.zshrc"
echo ""
echo "  2. Verify the toolkit aliases are active:"
echo "       type kubectl"
echo "       # Expected: kubectl is an alias for docker run ..."
echo ""

if docker image inspect devops-toolkit:latest >/dev/null 2>&1; then
  echo "  3. Follow the rebuild runbook:"
  echo "       documentation/rebuild-runbook.md"
else
  echo "  3. Build the toolkit image:"
  echo "       cd \"${FINAL_TOOLKIT_DIR}\" && make build"
  echo ""
  echo "  4. Follow the rebuild runbook:"
  echo "       documentation/rebuild-runbook.md"
fi
echo ""
