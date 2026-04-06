#!/usr/bin/env bash
# scripts/gitea-init.sh
# Idempotent Gitea setup — safe to re-run.
# Creates the poc org, all four repos, a runner registration token,
# and registers the repo credential in ArgoCD.
#
# Prerequisites:
#   - Gitea is healthy at https://gitea.test
#   - ArgoCD is healthy at https://argocd.test
#   - gitea-admin-secret Kubernetes Secret exists (created in runbook Step 1)
#   - pf-argocd NOT needed — ArgoCD CLI talks to argocd.test via Traefik
#
# Usage:
#   bash scripts/gitea-init.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[gitea-init]${NC} $*"; }
warn() { echo -e "${YELLOW}[gitea-init]${NC} $*"; }
err()  { echo -e "${RED}[gitea-init] ERROR:${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BLUE}── $* ──${NC}"; }

GITEA_URL="https://gitea.test"
GITEA_USER="poc-admin"
GITEA_ORG="poc"

# Read admin password from the Kubernetes secret — single source of truth
GITEA_PASS=$(docker run --rm \
  --network host \
  -v "${POC_DIR}/kube:/root/.kube" \
  -e KUBECONFIG=/root/.kube/config \
  devops-toolkit:latest \
  kubectl get secret gitea-admin-secret -n gitea \
  -o jsonpath='{.data.password}' | base64 -d | tr -d '\r\n')

if [[ -z "${GITEA_PASS}" ]]; then
  err "Could not read gitea-admin-secret from namespace gitea. Is Gitea deployed?"
fi

# Helper — Gitea API call. Uses toolkit container for curl + CA trust.
gitea_api() {
  local method="$1"; local path="$2"; shift 2
  docker run --rm --network host \
    devops-toolkit:latest \
    curl -sk -X "${method}" \
    -u "${GITEA_USER}:${GITEA_PASS}" \
    -H "Content-Type: application/json" \
    "${GITEA_URL}/api/v1${path}" \
    "$@"
}

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight — Gitea connectivity"
HTTP=$(docker run --rm --network host devops-toolkit:latest \
  curl -sk -o /dev/null -w "%{http_code}" \
  -u "${GITEA_USER}:${GITEA_PASS}" \
  "${GITEA_URL}/api/v1/user")

if [[ "${HTTP}" != "200" ]]; then
  err "Gitea API returned HTTP ${HTTP}. Is Gitea healthy at ${GITEA_URL}?"
fi
log "Gitea reachable — API returned 200"

# ── Organisation ──────────────────────────────────────────────────────────────
step "Organisation: ${GITEA_ORG}"
ORG_EXISTS=$(gitea_api GET "/orgs/${GITEA_ORG}" | docker run --rm -i devops-toolkit:latest jq -r '.name // empty')

if [[ "${ORG_EXISTS}" == "${GITEA_ORG}" ]]; then
  warn "org '${GITEA_ORG}' already exists — skipping"
else
  gitea_api POST "/orgs" -d "{
    \"username\": \"${GITEA_ORG}\",
    \"visibility\": \"private\",
    \"description\": \"PoC sensor demo organisation\"
  }" | docker run --rm -i devops-toolkit:latest jq -r '.name'
  log "org '${GITEA_ORG}' created"
fi

# ── Repositories ──────────────────────────────────────────────────────────────
step "Repositories"
REPOS=(sensor-producer mqtt-bridge event-consumer sensor-demo-deploy)

for REPO in "${REPOS[@]}"; do
  REPO_EXISTS=$(gitea_api GET "/repos/${GITEA_ORG}/${REPO}" | \
    docker run --rm -i devops-toolkit:latest jq -r '.name // empty')

  if [[ "${REPO_EXISTS}" == "${REPO}" ]]; then
    warn "repo '${GITEA_ORG}/${REPO}' already exists — skipping"
  else
    gitea_api POST "/orgs/${GITEA_ORG}/repos" -d "{
      \"name\": \"${REPO}\",
      \"private\": false,
      \"description\": \"PoC sensor demo — ${REPO}\",
      \"auto_init\": true,
      \"default_branch\": \"main\"
    }" | docker run --rm -i devops-toolkit:latest jq -r '.full_name'
    log "repo '${GITEA_ORG}/${REPO}' created"
  fi
done

# ── Actions runner registration token ─────────────────────────────────────────
# Creates a registration token at org level — one runner serves all repos in poc org.
step "Actions runner registration token"
RUNNER_TOKEN=$(gitea_api POST "/orgs/${GITEA_ORG}/actions/runners/registration-token" \
  | docker run --rm -i devops-toolkit:latest jq -r '.token')

if [[ -z "${RUNNER_TOKEN}" || "${RUNNER_TOKEN}" == "null" ]]; then
  err "Failed to create runner registration token"
fi

log "runner registration token obtained"

# Store token as a Kubernetes secret for the runner deployment to consume
EXISTING_RUNNER_SECRET=$(docker run --rm --network host \
  -v "${POC_DIR}/kube:/root/.kube" \
  -e KUBECONFIG=/root/.kube/config \
  devops-toolkit:latest \
  kubectl get secret gitea-runner-token -n gitea --ignore-not-found \
  -o jsonpath='{.metadata.name}')

if [[ -n "${EXISTING_RUNNER_SECRET}" ]]; then
  warn "gitea-runner-token secret already exists — updating"
  docker run --rm --network host \
    -v "${POC_DIR}/kube:/root/.kube" \
    -e KUBECONFIG=/root/.kube/config \
    devops-toolkit:latest \
    kubectl create secret generic gitea-runner-token \
      -n gitea \
      --from-literal=token="${RUNNER_TOKEN}" \
      --dry-run=client -o yaml \
  | docker run --rm -i --network host \
    -v "${POC_DIR}/kube:/root/.kube" \
    -e KUBECONFIG=/root/.kube/config \
    devops-toolkit:latest \
    kubectl apply -f -
else
  docker run --rm --network host \
    -v "${POC_DIR}/kube:/root/.kube" \
    -e KUBECONFIG=/root/.kube/config \
    devops-toolkit:latest \
    kubectl create secret generic gitea-runner-token \
      -n gitea \
      --from-literal=token="${RUNNER_TOKEN}"
  log "gitea-runner-token secret created in namespace gitea"
fi

# ── Gitea API token for ArgoCD ────────────────────────────────────────────────
# Creates a long-lived API token scoped to reading repositories.
# ArgoCD uses this to poll sensor-demo-deploy for changes.
step "ArgoCD repository credential token"

# Delete and recreate — idempotent pattern (Gitea tokens can't be read back)
gitea_api DELETE "/users/${GITEA_USER}/tokens/argocd-readonly" >/dev/null 2>&1 || true

ARGOCD_TOKEN=$(gitea_api POST "/users/${GITEA_USER}/tokens" -d '{
  "name": "argocd-readonly",
  "scopes": ["read:repository"]
}' | docker run --rm -i devops-toolkit:latest jq -r '.sha1')

if [[ -z "${ARGOCD_TOKEN}" || "${ARGOCD_TOKEN}" == "null" ]]; then
  err "Failed to create ArgoCD API token"
fi
log "ArgoCD API token created"

# Store in Kubernetes secret — ArgoCD repo secret refs it
ARGOCD_REPO_SECRET_EXISTS=$(docker run --rm --network host \
  -v "${POC_DIR}/kube:/root/.kube" \
  -e KUBECONFIG=/root/.kube/config \
  devops-toolkit:latest \
  kubectl get secret gitea-argocd-creds -n argocd --ignore-not-found \
  -o jsonpath='{.metadata.name}')

if [[ -n "${ARGOCD_REPO_SECRET_EXISTS}" ]]; then
  warn "gitea-argocd-creds already exists — updating"
fi

docker run --rm --network host \
  -v "${POC_DIR}/kube:/root/.kube" \
  -e KUBECONFIG=/root/.kube/config \
  devops-toolkit:latest \
  kubectl create secret generic gitea-argocd-creds \
    -n argocd \
    --from-literal=username="${GITEA_USER}" \
    --from-literal=password="${ARGOCD_TOKEN}" \
    --from-literal=url="http://gitea-http.gitea.svc.cluster.local:3000/${GITEA_ORG}/sensor-demo-deploy" \
    --dry-run=client -o yaml \
| docker run --rm -i --network host \
  -v "${POC_DIR}/kube:/root/.kube" \
  -e KUBECONFIG=/root/.kube/config \
  devops-toolkit:latest \
  kubectl apply -f -

# Label it so ArgoCD picks it up as a repo credential automatically
docker run --rm --network host \
  -v "${POC_DIR}/kube:/root/.kube" \
  -e KUBECONFIG=/root/.kube/config \
  devops-toolkit:latest \
  kubectl label secret gitea-argocd-creds -n argocd \
    argocd.argoproj.io/secret-type=repository \
    --overwrite

log "gitea-argocd-creds secret created and labelled in namespace argocd"

# ── Image pull secret for Gitea registry ──────────────────────────────────────
# k3d nodes pull images tagged with gitea.test — the secret server must match.
# Create a docker-registry secret in each sensor namespace so pods can pull
# images built by CI and pushed to the Gitea container registry.
# The secret is referenced via imagePullSecrets on each ServiceAccount.
step "Gitea registry pull secret"
SENSOR_NAMESPACES=(sensor-dev sensor-qa sensor-prod)

for NS in "${SENSOR_NAMESPACES[@]}"; do
  # Ensure namespace exists (may not yet if ArgoCD hasn't synced)
  docker run --rm --network host     -v "${POC_DIR}/kube:/root/.kube"     -e KUBECONFIG=/root/.kube/config     devops-toolkit:latest     kubectl create namespace "${NS}" --dry-run=client -o yaml   | docker run --rm -i --network host     -v "${POC_DIR}/kube:/root/.kube"     -e KUBECONFIG=/root/.kube/config     devops-toolkit:latest     kubectl apply -f -

  # Check if secret already exists
  EXISTING=$(docker run --rm --network host     -v "${POC_DIR}/kube:/root/.kube"     -e KUBECONFIG=/root/.kube/config     devops-toolkit:latest     kubectl get secret gitea-registry -n "${NS}" --ignore-not-found     -o jsonpath='{.metadata.name}')

  if [[ -n "${EXISTING}" ]]; then
    warn "gitea-registry pull secret already exists in ${NS} — updating"
  fi

  docker run --rm --network host     -v "${POC_DIR}/kube:/root/.kube"     -e KUBECONFIG=/root/.kube/config     devops-toolkit:latest     kubectl create secret docker-registry gitea-registry       -n "${NS}"       --docker-server=gitea.test       --docker-username="${GITEA_USER}"       --docker-password="${GITEA_PASS}"       --dry-run=client -o yaml   | docker run --rm -i --network host     -v "${POC_DIR}/kube:/root/.kube"     -e KUBECONFIG=/root/.kube/config     devops-toolkit:latest     kubectl apply -f -

  log "gitea-registry pull secret created/updated in namespace ${NS}"
done

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
log "gitea-init.sh complete"
echo ""
echo "  Org:   ${GITEA_URL}/${GITEA_ORG}"
echo "  Repos:"
for REPO in "${REPOS[@]}"; do
  echo "    ${GITEA_URL}/${GITEA_ORG}/${REPO}"
done
echo ""
echo "  Runner token stored in: kubectl get secret gitea-runner-token -n gitea"
echo "  ArgoCD creds stored in: kubectl get secret gitea-argocd-creds -n argocd"
echo "  Registry pull secrets:  gitea-registry in sensor-dev, sensor-qa, sensor-prod"
echo ""
echo "  Next: start the host Actions runner"
echo "    runner-start"
