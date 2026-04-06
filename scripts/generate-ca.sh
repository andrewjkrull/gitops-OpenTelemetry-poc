#!/usr/bin/env bash
# scripts/generate-ca.sh
# Generates a self-signed CA certificate for the PoC.
# Run ONCE per machine — the CA persists across all cluster rebuilds.
#
# The CA key and cert live in ${POC_DIR}/vault/ (gitignored alongside the
# Vault unseal key and root token). They are intentionally NOT deleted by
# cluster-delete.sh — they survive rebuilds by design.
#
# Only re-run this script if you need to rotate the CA. Rotation requires
# a full cluster rebuild and re-import into Vault.
#
# What this does:
#   1. Checks if CA already exists — prompts before overwriting
#   2. Generates a 4096-bit RSA CA key and self-signed cert (10yr validity)
#   3. Installs the cert into the Linux host trust store
#   4. Restarts Docker so the daemon trusts the new CA immediately
#
# Usage:
#   bash scripts/generate-ca.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[generate-ca]${NC} $*"; }
warn() { echo -e "${YELLOW}[generate-ca]${NC} $*"; }
err()  { echo -e "${RED}[generate-ca] ERROR:${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BLUE}── $* ──${NC}"; }

CA_KEY="${POC_DIR}/vault/poc-ca.key"
CA_CERT="${POC_DIR}/vault/poc-ca.crt"
HOST_CA_DEST="/usr/local/share/ca-certificates/poc-ca.crt"

mkdir -p "${POC_DIR}/vault"
chmod 700 "${POC_DIR}/vault"

# ── Check if CA already exists ────────────────────────────────────────────────
step "Checking existing CA"

if [[ -f "${CA_KEY}" && -f "${CA_CERT}" ]]; then
  EXPIRY=$(openssl x509 -in "${CA_CERT}" -noout -enddate 2>/dev/null | cut -d= -f2)
  warn "CA already exists:"
  warn "  Key:    ${CA_KEY}"
  warn "  Cert:   ${CA_CERT}"
  warn "  Expiry: ${EXPIRY}"
  echo ""
  echo "  The existing CA is reused across cluster rebuilds."
  echo "  Only regenerate if you need to rotate the CA."
  echo ""
  echo "  Press Ctrl+C to keep existing CA (recommended)"
  read -r -p "  Type 'rotate' to generate a new CA: " CONFIRM
  if [[ "${CONFIRM}" != "rotate" ]]; then
    log "Keeping existing CA."
    # Ensure it's installed in the host trust store
    if ! diff -q "${CA_CERT}" "${HOST_CA_DEST}" >/dev/null 2>&1; then
      step "Installing CA into host trust store"
      sudo cp "${CA_CERT}" "${HOST_CA_DEST}"
      sudo update-ca-certificates
      log "Trust store updated — restarting Docker..."
      sudo systemctl restart docker
      log "Done."
    else
      log "Host trust store already up to date — nothing to do."
    fi
    exit 0
  fi
  warn "Generating new CA — existing files will be overwritten."
  warn "You must rebuild the cluster and re-run vault-init.sh after this."
fi

# ── Generate CA key and certificate ──────────────────────────────────────────
step "Generating CA key and certificate"

log "generating 4096-bit RSA key..."
openssl genrsa -out "${CA_KEY}" 4096 2>/dev/null
chmod 600 "${CA_KEY}"
log "key written to ${CA_KEY}"

log "generating self-signed CA certificate (10 year validity)..."
openssl req -new -x509 \
  -key "${CA_KEY}" \
  -out "${CA_CERT}" \
  -days 3650 \
  -subj "/CN=poc-root-ca/O=PoC/C=US" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" \
  2>/dev/null
chmod 644 "${CA_CERT}"

SUBJECT=$(openssl x509 -in "${CA_CERT}" -noout -subject 2>/dev/null)
EXPIRY=$(openssl x509 -in "${CA_CERT}" -noout -enddate 2>/dev/null)
log "cert written to ${CA_CERT}"
log "  ${SUBJECT}"
log "  ${EXPIRY}"

# ── Install into Linux host trust store ───────────────────────────────────────
step "Installing CA into Linux host trust store"

sudo cp "${CA_CERT}" "${HOST_CA_DEST}"
sudo update-ca-certificates
log "host trust store updated"

# ── Restart Docker ─────────────────────────────────────────────────────────────
step "Restarting Docker daemon"

sudo systemctl restart docker
log "Docker restarted — daemon now trusts the new CA"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
log "generate-ca.sh complete"
echo ""
echo "  CA files:"
echo "    ${CA_KEY}"
echo "    ${CA_CERT}"
echo ""
echo "  These files persist across cluster rebuilds."
echo "  cluster-delete.sh will NOT remove them."
echo ""
echo "  Next step: bash ${POC_DIR}/scripts/cluster-create.sh"
echo ""
