#!/usr/bin/env bash
# scripts/app-repos-init.sh
# Pushes the three application source repos to Gitea and adds the
# Gitea Actions CI workflow to each.
#
# What this does:
#   1. For each app (sensor-producer, mqtt-bridge, event-consumer):
#      a. Initialises a git repo in apps/<app>/
#      b. Adds the .gitea/workflows/build.yml CI workflow
#      c. Commits everything
#      d. Pushes to https://gitea.test/poc/<app>
#
# Prerequisites:
#   - Gitea running at https://gitea.test
#   - gitea-init.sh already run (repos exist)
#   - App source files in ${POC_DIR}/apps/<app>/
#   - git configured on the host (user.email and user.name set)
#
# Usage:
#   bash scripts/app-repos-init.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[app-repos-init]${NC} $*"; }
warn() { echo -e "${YELLOW}[app-repos-init]${NC} $*"; }
err()  { echo -e "${RED}[app-repos-init] ERROR:${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BLUE}── $* ──${NC}"; }

GITEA_URL="https://gitea.test"
GITEA_USER="poc-admin"

# Read Gitea password from Kubernetes secret
GITEA_PASS=$(docker run --rm --network host \
  -v "${POC_DIR}/kube:/root/.kube" \
  -e KUBECONFIG=/root/.kube/config \
  devops-toolkit:latest \
  kubectl get secret gitea-admin-secret -n gitea \
  -o jsonpath='{.data.password}' | base64 -d | tr -d '\r\n')

if [[ -z "${GITEA_PASS}" ]]; then
  err "Could not read gitea-admin-secret. Is Gitea deployed?"
fi

# ── Preflight ─────────────────────────────────────────────────────────────────
step "Preflight"

GIT_EMAIL=$(git config --global user.email 2>/dev/null || true)
GIT_NAME=$(git config --global user.name 2>/dev/null || true)
if [[ -z "${GIT_EMAIL}" || -z "${GIT_NAME}" ]]; then
  err "git user not configured. Run:
  git config --global user.email \"you@example.com\"
  git config --global user.name \"Your Name\""
fi
log "git user: ${GIT_NAME} <${GIT_EMAIL}>"

APPS=(sensor-producer mqtt-bridge event-consumer)

for APP in "${APPS[@]}"; do
  APP_DIR="${POC_DIR}/apps/${APP}"
  if [[ ! -f "${APP_DIR}/Program.cs" ]]; then
    err "App source not found at ${APP_DIR}/Program.cs — ensure app code is in place"
  fi
done
log "All app source files present"

# ── Push each app repo ────────────────────────────────────────────────────────
for APP in "${APPS[@]}"; do
  step "${APP}"

  APP_DIR="${POC_DIR}/apps/${APP}"

  # Create .gitea/workflows directory and workflow file
  mkdir -p "${APP_DIR}/.gitea/workflows"

  cat > "${APP_DIR}/.gitea/workflows/build.yml" << WORKFLOW
# .gitea/workflows/build.yml
# CI workflow for ${APP}.
# Triggers on push to main — builds Docker image, pushes to Gitea registry,
# and commits the new image tag to sensor-demo-deploy for ArgoCD to sync.
#
# Secrets required (set at org level):
#   REGISTRY_USER     — Gitea username (poc-admin)
#   REGISTRY_PASSWORD — Gitea admin password
#   CI_DEPLOY_TOKEN   — Gitea API token with write:repository scope

name: Build and Deploy

on:
  push:
    branches:
      - main

env:
  REGISTRY: gitea.test
  IMAGE: gitea.test/poc/${APP}

jobs:
  build-and-push:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout source
        uses: actions/checkout@v3

      - name: Install CA certificate
        run: update-ca-certificates

      - name: Set image tag
        id: tag
        run: echo "sha=\${GITHUB_SHA::8}" >> \$GITHUB_OUTPUT

      - name: Login to Gitea registry
        run: |
          echo "\${{ secrets.REGISTRY_PASSWORD }}" | \\
            docker login \${{ env.REGISTRY }} \\
              -u \${{ secrets.REGISTRY_USER }} \\
              --password-stdin

      - name: Build image
        run: |
          docker build \\
            -t \${{ env.IMAGE }}:\${{ steps.tag.outputs.sha }} \\
            -t \${{ env.IMAGE }}:latest \\
            .

      - name: Push image
        run: |
          docker push \${{ env.IMAGE }}:\${{ steps.tag.outputs.sha }}
          docker push \${{ env.IMAGE }}:latest

      - name: Update image tag in deploy repo
        run: |
          git config --global user.email "ci@gitea.test"
          git config --global user.name "Gitea CI"

          git clone \\
            https://poc-admin:\${{ secrets.CI_DEPLOY_TOKEN }}@gitea.test/poc/sensor-demo-deploy.git \\
            /tmp/deploy-repo

          cd /tmp/deploy-repo/envs/dev

          # Update newName and newTag for this app by matching on the stable
          # "- name: ${APP}" line. Works on both first run (newName: busybox)
          # and subsequent runs (newName: gitea.test/poc/${APP}).
          sed -i "/- name: ${APP}/{
            n
            s|newName:.*|newName: \${{ env.IMAGE }}|
            n
            s|newTag:.*|newTag: \${{ steps.tag.outputs.sha }}|
          }" kustomization.yaml

          cd /tmp/deploy-repo
          git add envs/dev/kustomization.yaml
          git diff --staged --quiet && echo "No tag change — skipping commit" && exit 0

          git commit -m "ci: update ${APP} to \${{ steps.tag.outputs.sha }}

          Built from \${{ github.sha }}
          Triggered by push to \${{ github.repository }}"

          git push origin main

      - name: Summary
        run: |
          echo "image=${APP}:\${{ steps.tag.outputs.sha }}" >> \$GITHUB_OUTPUT || true
          echo "Built and pushed \${{ env.IMAGE }}:\${{ steps.tag.outputs.sha }}"
WORKFLOW

  log "workflow written to ${APP_DIR}/.gitea/workflows/build.yml"

  # Initialise git repo if not already done
  if [[ ! -d "${APP_DIR}/.git" ]]; then
    git -C "${APP_DIR}" init
    git -C "${APP_DIR}" checkout -b main
    log "git repo initialised"
  else
    warn "git repo already initialised — using existing"
  fi

  # Set remote — overwrite if exists
  git -C "${APP_DIR}" remote remove origin 2>/dev/null || true
  git -C "${APP_DIR}" remote add origin \
    "https://${GITEA_USER}:${GITEA_PASS}@gitea.test/poc/${APP}.git"

  # Stage all files
  git -C "${APP_DIR}" add .
  git -C "${APP_DIR}" status

  # Commit — skip if nothing to commit
  if git -C "${APP_DIR}" diff --staged --quiet; then
    warn "nothing to commit for ${APP} — skipping"
  else
    git -C "${APP_DIR}" commit -m "feat: initial ${APP} implementation

- .NET 6 Worker Service with OTLP distributed tracing
- W3C trace context propagation across messaging protocols
- Vault Agent secret injection (reads from /vault/secrets/*.env)
- Gitea Actions CI workflow for build and deploy"
    log "committed"
  fi

  # Push to Gitea
  git -C "${APP_DIR}" push -u origin main --force
  log "${APP} pushed to ${GITEA_URL}/poc/${APP}"

done

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
log "app-repos-init.sh complete"
echo ""
echo "  Repos:"
for APP in "${APPS[@]}"; do
  echo "    ${GITEA_URL}/poc/${APP}"
done
echo ""
echo "  Next steps:"
echo "    1. Open https://gitea.test/poc/sensor-producer/actions"
echo "       — the build workflow should trigger automatically on the push"
echo "    2. Watch the build run in the Actions tab"
echo "    3. After all three builds complete, check ArgoCD — sensor-demo-dev"
echo "       should sync automatically with the real images"
echo "    4. Verify pods in sensor-dev are running the real app images (not busybox)"
