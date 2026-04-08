# ============================================================
# devops-toolkit container config
# Source: ~/.zshrc.d/poc-toolkit.zsh
# ============================================================

# ============================================================
# Project paths — set these to match your local layout
# All other paths in this file derive from these two variables.
# ============================================================
export POC_DIR="${HOME}/Projects/poc"
export TOOLKIT_DIR="${HOME}/Projects/docker-devops"
# docker-devops repo: https://github.com/andrewjkrull/docker-devops

# ============================================================
# Sync configuration
# Used by poc-sync-push and poc-sync-pull.
#
# POC_SERVER     — SSH target for the Linux host running the cluster
#                  Format: user@hostname  or  user@ip
# POC_SERVER_DIR — Path to the poc directory on the server
#
# poc-sync-push: run on your workstation — pushes source files to server
# poc-sync-pull: run on the server — pulls source files from workstation
#
# Both functions exclude runtime state (vault/, kube/, tmp/, helm-cache/)
# so machine-specific files are never overwritten.
# ============================================================
export POC_SERVER="your-user@devajk01"
export POC_SERVER_DIR="~/Projects/poc"

# ============================================================
# Toolkit image
# ============================================================
export TOOLKIT_IMAGE="devops-toolkit:latest"

# ============================================================
# Persistent volume mounts
# ============================================================
export TOOLKIT_MOUNTS="\
  -v ${POC_DIR}/manifests:/work \
  -v ${POC_DIR}/kube:/root/.kube \
  -v ${POC_DIR}/helm-cache:/root/.cache/helm \
  -v ${POC_DIR}/helm-config:/root/.config/helm \
  -v ${POC_DIR}/vault:/root/.vault \
  -v ${POC_DIR}/tmp:/tmp/poc \
  -v /var/run/docker.sock:/var/run/docker.sock"

# ============================================================
# Standard env vars passed into every container
# ============================================================
export TOOLKIT_ENV="\
  -e KUBECONFIG=/root/.kube/config \
  -e HELM_CACHE_HOME=/root/.cache/helm \
  -e HELM_CONFIG_HOME=/root/.config/helm \
  -e VAULT_TOKEN_PATH=/root/.vault/token"

# ============================================================
# Tool aliases
# ============================================================
alias kubectl="docker run --rm -it --network host \
  ${TOOLKIT_MOUNTS} ${TOOLKIT_ENV} \
  --name toolkit-kubectl ${TOOLKIT_IMAGE} kubectl"

alias helm="docker run --rm -it --network host \
  ${TOOLKIT_MOUNTS} ${TOOLKIT_ENV} \
  --name toolkit-helm ${TOOLKIT_IMAGE} helm"

alias k3d="docker run --rm -it --network host \
  ${TOOLKIT_MOUNTS} ${TOOLKIT_ENV} \
  --name toolkit-k3d ${TOOLKIT_IMAGE} k3d"

alias vault="docker run --rm -it --network host \
  ${TOOLKIT_MOUNTS} ${TOOLKIT_ENV} \
  --name toolkit-vault ${TOOLKIT_IMAGE} vault"

alias yq="docker run --rm -it \
  -v ${POC_DIR}/manifests:/work \
  --name toolkit-yq ${TOOLKIT_IMAGE} yq"

alias trivy="docker run --rm -it \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ${POC_DIR}/tmp:/tmp/poc \
  --name toolkit-trivy ${TOOLKIT_IMAGE} trivy"

alias grype="docker run --rm -it \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --name toolkit-grype ${TOOLKIT_IMAGE} grype"

alias syft="docker run --rm -it \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --name toolkit-syft ${TOOLKIT_IMAGE} syft"

alias sops="docker run --rm -it \
  -v ${POC_DIR}/manifests:/work \
  -v ${HOME}/.config/sops:/root/.config/sops \
  --name toolkit-sops ${TOOLKIT_IMAGE} sops"

alias age="docker run --rm -it \
  -v ${POC_DIR}/manifests:/work \
  --name toolkit-age ${TOOLKIT_IMAGE} age"

alias gitleaks="docker run --rm -it \
  -v ${POC_DIR}/manifests:/work \
  --name toolkit-gitleaks ${TOOLKIT_IMAGE} gitleaks"

alias ansible="docker run --rm -it \
  -v ${POC_DIR}/iac:/work \
  --name toolkit-ansible ${TOOLKIT_IMAGE} ansible"

alias ansible-playbook="docker run --rm -it \
  -v ${POC_DIR}/iac:/work \
  --name toolkit-ansible-playbook ${TOOLKIT_IMAGE} ansible-playbook"

alias k="kubectl"

# ============================================================
# Port-forward aliases
# Run each in a dedicated terminal tab — leave running for the session
# ============================================================

# Vault API + UI — required for PKI and cert-manager
# Access: http://127.0.0.1:8200  Token: see ${POC_DIR}/vault/root-token
alias pf-vault="docker run --rm -it --network host \
  -v ${POC_DIR}/kube:/root/.kube \
  -e KUBECONFIG=/root/.kube/config \
  --name pf-vault \
  ${TOOLKIT_IMAGE} \
  kubectl port-forward svc/vault -n vault 8200:8200"

# Elasticsearch API — required for index management and obs-init.sh
# Access: https://127.0.0.1:9200
alias pf-es="docker run --rm -it --network host \
  -v ${POC_DIR}/kube:/root/.kube \
  -e KUBECONFIG=/root/.kube/config \
  --name pf-es \
  ${TOOLKIT_IMAGE} \
  kubectl port-forward svc/elasticsearch-es-http -n observability 9200:9200"

# Kibana direct access — only needed to bypass Traefik for debugging
# Normal access is via https://kibana.test through Traefik
alias pf-kibana="docker run --rm -it --network host \
  -v ${POC_DIR}/kube:/root/.kube \
  -e KUBECONFIG=/root/.kube/config \
  --name pf-kibana \
  ${TOOLKIT_IMAGE} \
  kubectl port-forward svc/kibana-kb-http -n observability 5601:5601"

# NOTE: pf-traefik removed — Traefik service does not expose port 9000.
# The Traefik API is on container port 8080 but not exposed via the Service.
# For Traefik API access use:
#   kubectl port-forward -n traefik \
#     $(kubectl get pod -n traefik -l app.kubernetes.io/name=traefik \
#       -o jsonpath='{.items[0].metadata.name}') 8080:8080

# ============================================================
# Phase 4 port-forward aliases
# gitea.test and argocd.test are routed through Traefik — no port-forward needed
# for normal use. These are for direct debugging only.
# ============================================================

# Gitea direct access — only needed to bypass Traefik for debugging
# Normal access is via https://gitea.test through Traefik
alias pf-gitea="docker run --rm -it --network host \
  -v ${POC_DIR}/kube:/root/.kube \
  -e KUBECONFIG=/root/.kube/config \
  --name pf-gitea \
  ${TOOLKIT_IMAGE} \
  kubectl port-forward svc/gitea-http -n gitea 3000:3000"

# ArgoCD direct access — only needed to bypass Traefik for debugging
# Normal access is via https://argocd.test through Traefik
alias pf-argocd="docker run --rm -it --network host \
  -v ${POC_DIR}/kube:/root/.kube \
  -e KUBECONFIG=/root/.kube/config \
  --name pf-argocd \
  ${TOOLKIT_IMAGE} \
  kubectl port-forward svc/argocd-server -n argocd 8080:80"

# ============================================================
# Vault PoC alias — VAULT_ADDR and TOKEN baked in
# ============================================================
alias vault-poc="docker run --rm -it --network host \
  ${TOOLKIT_MOUNTS} ${TOOLKIT_ENV} \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  -e VAULT_TOKEN=$(cat ${POC_DIR}/vault/root-token 2>/dev/null || echo not-set) \
  --name toolkit-vault ${TOOLKIT_IMAGE} vault"

# ============================================================
# Interactive toolkit shell
# ============================================================
alias toolkit="docker run --rm -it --network host \
  ${TOOLKIT_MOUNTS} ${TOOLKIT_ENV} \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  -e VAULT_TOKEN=$(cat ${POC_DIR}/vault/root-token 2>/dev/null || echo not-set) \
  --name toolkit-session \
  ${TOOLKIT_IMAGE} bash"

# ============================================================
# Completions
# Run toolkit-completions-init once after install or image update
# ============================================================
[[ -f ~/.zshrc.d/poc-completions/_kubectl ]] \
  && source ~/.zshrc.d/poc-completions/_kubectl

[[ -f ~/.zshrc.d/poc-completions/_helm ]] \
  && source ~/.zshrc.d/poc-completions/_helm

compdef k=kubectl 2>/dev/null

# ============================================================
# Functions
# ============================================================

kns() {
  # Switch namespace — Usage: kns apps
  kubectl config set-context --current --namespace="$1"
}

kctx() {
  # Show or switch context
  # Usage: kctx            shows current
  #        kctx k3d-poc    switches to k3d-poc
  if [[ -z "$1" ]]; then
    kubectl config current-context
  else
    kubectl config use-context "$1"
  fi
}

toolkit-completions-init() {
  # Generate completion files from the container
  # Run once after first install, and again after toolkit image updates
  echo "Generating completions from ${TOOLKIT_IMAGE}..."
  mkdir -p ~/.zshrc.d/poc-completions
  docker run --rm ${TOOLKIT_IMAGE} kubectl completion zsh \
    > ~/.zshrc.d/poc-completions/_kubectl
  docker run --rm ${TOOLKIT_IMAGE} helm completion zsh \
    > ~/.zshrc.d/poc-completions/_helm
  echo "Done — reload with: source ~/.zshrc"
}

toolkit-pull() {
  # Pull latest toolkit image
  docker pull ${TOOLKIT_IMAGE}
}

toolkit-build() {
  # Rebuild the toolkit image from source
  # Repo: https://github.com/andrewjkrull/docker-devops
  # Clone it first if not present:
  #   git clone https://github.com/andrewjkrull/docker-devops "${TOOLKIT_DIR}"
  echo "Building ${TOOLKIT_IMAGE} from ${TOOLKIT_DIR}..."
  cd "${TOOLKIT_DIR}" && make build
}

poc-dirs() {
  # Ensure the working directory structure exists
  # Run once on initial setup or after cloning the repo
  mkdir -p ${POC_DIR}/{manifests,tmp,kube,helm-cache,helm-config,vault}
  mkdir -p ${POC_DIR}/{documentation,scripts,context-history}
  mkdir -p ${POC_DIR}/apps/{sensor-producer,mqtt-bridge,event-consumer,sensor-demo-deploy}
  echo "poc directories ready under ${POC_DIR}/"
}

poc-sync-push() {
  # Push source files from this machine to the server.
  # Run on your workstation (WSL or Linux desktop).
  #
  # Excludes runtime state that must never be overwritten:
  #   vault/       — CA key, CA cert, root token, unseal keys (machine-specific)
  #   kube/        — kubeconfig (cluster-specific)
  #   tmp/         — ephemeral runtime state
  #   helm-cache/  — local Helm chart cache
  #   helm-config/ — local Helm config
  #   context-history/ — local snapshots
  #
  # POC_SERVER and POC_SERVER_DIR must be set at the top of this file.
  #
  # Usage: poc-sync-push
  #        poc-sync-push --dry-run   (preview without making changes)

  if [[ "${POC_SERVER}" == "your-user@devajk01" ]]; then
    echo "ERROR: POC_SERVER is not configured."
    echo "Edit ~/.zshrc.d/poc-toolkit.zsh and set POC_SERVER at the top."
    return 1
  fi

  local dry_run=""
  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run="--dry-run"
    echo "==> DRY RUN — no files will be changed"
  fi

  echo "==> Pushing from ${POC_DIR}"
  echo "    to          ${POC_SERVER}:${POC_SERVER_DIR}"
  echo ""

  rsync -av --progress ${dry_run} \
    --exclude='vault/' \
    --exclude='kube/' \
    --exclude='tmp/' \
    --exclude='helm-cache/' \
    --exclude='helm-config/' \
    --exclude='context-history/' \
    --exclude='.git/' \
    --exclude='*.pyc' \
    "${POC_DIR}/" \
    "${POC_SERVER}:${POC_SERVER_DIR}/"

  echo ""
  echo "==> Push complete"
  echo "    vault/, kube/, tmp/, helm-cache/ on server were NOT touched"
}

poc-sync-pull() {
  # Pull source files from the workstation to this server.
  # Run on the Linux server (all-Linux home setup where SSH works both ways).
  #
  # Excludes runtime state that must never be overwritten:
  #   vault/       — CA key, CA cert, root token, unseal keys (machine-specific)
  #   kube/        — kubeconfig (cluster-specific)
  #   tmp/         — ephemeral runtime state
  #   helm-cache/  — local Helm chart cache
  #   helm-config/ — local Helm config
  #   context-history/ — local snapshots
  #
  # POC_SERVER and POC_SERVER_DIR must be set at the top of this file.
  # In pull mode POC_SERVER is the workstation you are pulling FROM.
  #
  # Usage: poc-sync-pull
  #        poc-sync-pull --dry-run   (preview without making changes)

  if [[ "${POC_SERVER}" == "your-user@devajk01" ]]; then
    echo "ERROR: POC_SERVER is not configured."
    echo "Edit ~/.zshrc.d/poc-toolkit.zsh and set POC_SERVER at the top."
    return 1
  fi

  local dry_run=""
  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run="--dry-run"
    echo "==> DRY RUN — no files will be changed"
  fi

  echo "==> Pulling from ${POC_SERVER}:${POC_DIR}"
  echo "    to           ${POC_DIR}"
  echo ""

  rsync -av --progress ${dry_run} \
    --exclude='vault/' \
    --exclude='kube/' \
    --exclude='tmp/' \
    --exclude='helm-cache/' \
    --exclude='helm-config/' \
    --exclude='context-history/' \
    --exclude='.git/' \
    --exclude='*.pyc' \
    "${POC_SERVER}:${POC_DIR}/" \
    "${POC_DIR}/"

  echo ""
  echo "==> Pull complete"
  echo "    vault/, kube/, tmp/, helm-cache/ were NOT touched"
}

es-pass() {
  # Retrieve Elasticsearch password from k8s secret
  # Pulls directly from k8s — reliable, no ANSI encoding issues
  # For manual login use the Vault UI at http://127.0.0.1:8200
  kubectl get secret elasticsearch-es-elastic-user \
    -n observability \
    -o jsonpath='{.data.elastic}' | base64 -d | tr -d '\r\n'
}

obs-init() {
  # Run observability init scripts in order — fresh cluster builds only
  # Requires: pf-vault and pf-es running in dedicated terminals
  # obs-init.sh  — creates ES index templates + otel-es-credentials secret
  # obs-ilm-init.sh — attaches 12h ILM delete policy to all three OTel data streams
  bash ${POC_DIR}/scripts/obs-init.sh \
    && bash ${POC_DIR}/scripts/obs-ilm-init.sh
}

gitea-token() {
  # Retrieve the Gitea admin password from the Kubernetes secret
  # Usage: gitea-token
  kubectl get secret gitea-admin-secret -n gitea \
    -o jsonpath='{.data.password}' | base64 -d | tr -d '\r\n'
  echo ""
}

argocd-pass() {
  # Retrieve the ArgoCD initial admin password
  # Usage: argocd-pass
  kubectl get secret argocd-initial-admin-secret -n argocd \
    -o jsonpath='{.data.password}' | base64 -d | tr -d '\r\n'
  echo ""
}

runner-start() {
  # Start the Gitea Actions runner as a host Docker container.
  # Runs on the Linux host where Docker socket and internet are available.
  # Uses --network host + /etc/hosts mount so job containers can reach
  # gitea.test via Traefik and the internet via the host's DNS.
  # Registration token is read from the Kubernetes secret created by gitea-init.sh.
  #
  # Note: on k3d, the runner must run on the host — k3d nodes are containers
  # themselves and do not expose a Docker socket to pods. On a real Kubernetes
  # cluster with real nodes, an in-cluster runner is preferred.

  if docker ps --format '{{.Names}}' | grep -q '^gitea-runner$'; then
    echo "==> Gitea runner already running — skipping"
    return 0
  fi

  if docker ps -a --format '{{.Names}}' | grep -q '^gitea-runner$'; then
    echo "==> Restarting existing gitea-runner container..."
    docker start gitea-runner
    echo "    Gitea runner started"
    return 0
  fi

  echo "==> Starting Gitea Actions runner..."
  RUNNER_TOKEN=$(docker run --rm --network host \
    -v ${POC_DIR}/kube:/root/.kube \
    -e KUBECONFIG=/root/.kube/config \
    ${TOOLKIT_IMAGE} \
    kubectl get secret gitea-runner-token -n gitea \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d | tr -d '\r\n' || true)

  if [[ -z "${RUNNER_TOKEN}" ]]; then
    echo "    WARNING: gitea-runner-token secret not found — skipping runner start"
    echo "    Run gitea-init.sh first if Gitea is deployed"
    return 0
  fi

  mkdir -p ${POC_DIR}/tmp/gitea-runner

  # Write runner config — sets job container options for CA cert and hosts file
  # Must exist before the runner starts or job containers get no custom options
  cat > ${POC_DIR}/tmp/gitea-runner/config.yml << 'RUNNER_CONFIG'
runner:
  labels:
    - "ubuntu-latest:docker://gitea/runner-images:ubuntu-latest"
    - "ubuntu-22.04:docker://gitea/runner-images:ubuntu-latest"
container:
  network: "host"
  options: >-
    -v /etc/hosts:/etc/hosts:ro
    -v /usr/local/share/ca-certificates:/usr/local/share/ca-certificates:ro
    -e SSL_CERT_DIR=/usr/local/share/ca-certificates
    -e GIT_SSL_CAINFO=/usr/local/share/ca-certificates/poc-ca.crt
    -e NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/poc-ca.crt
    -e SSL_CERT_FILE=/usr/local/share/ca-certificates/poc-ca.crt
  valid_volumes:
    - '**'
  force_pull: false
RUNNER_CONFIG

  echo "    Runner config written to ${POC_DIR}/tmp/gitea-runner/config.yml"

  docker run -d \
    --name gitea-runner \
    --restart unless-stopped \
    --network host \
    -v /etc/hosts:/etc/hosts:ro \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v ${POC_DIR}/vault/poc-ca.crt:/usr/local/share/ca-certificates/poc-ca.crt:ro \
    -v ${POC_DIR}/tmp/gitea-runner:/data \
    -e GITEA_INSTANCE_URL=https://gitea.test \
    -e GITEA_RUNNER_REGISTRATION_TOKEN="${RUNNER_TOKEN}" \
    -e GITEA_RUNNER_NAME=poc-runner \
    -e GITEA_RUNNER_LABELS="ubuntu-latest:docker://gitea/runner-images:ubuntu-latest,ubuntu-22.04:docker://gitea/runner-images:ubuntu-latest" \
    -e SSL_CERT_DIR=/usr/local/share/ca-certificates \
    -e CONFIG_FILE=/data/config.yml \
    gitea/act_runner:latest

  echo "    Gitea runner started"
  echo "    Logs: docker logs gitea-runner --tail=20"
}

runner-stop() {
  # Stop the Gitea Actions runner host container
  if docker ps --format '{{.Names}}' | grep -q '^gitea-runner$'; then
    docker stop gitea-runner
    echo "Gitea runner stopped"
  else
    echo "Gitea runner was not running"
  fi
}

poc-start() {
  # Restore a running PoC session after cluster restart.
  # Does NOT run init scripts — those are for fresh cluster builds only.
  #
  # Fresh cluster build order (run once, follow rebuild-runbook.md):
  #   bash scripts/vault-init.sh
  #   obs-init
  #   bash scripts/messaging-init.sh
  #   bash scripts/gitea-init.sh
  #   bash scripts/deploy-repo-init.sh
  #   bash scripts/app-repos-init.sh

  # Step 1: Wait for Vault pod to be Ready
  echo "==> Waiting for Vault pod to be Ready..."
  docker run --rm --network host \
    -v ${POC_DIR}/kube:/root/.kube \
    -e KUBECONFIG=/root/.kube/config \
    ${TOOLKIT_IMAGE} \
    kubectl wait pod \
      -l app.kubernetes.io/name=vault \
      -n vault \
      --for=condition=Ready \
      --timeout=120s

  # Step 2: Start Vault port-forward in background
  echo ""
  echo "==> Starting Vault port-forward..."
  docker run --rm -d --network host \
    --name pf-vault-bg \
    -v ${POC_DIR}/kube:/root/.kube \
    -e KUBECONFIG=/root/.kube/config \
    ${TOOLKIT_IMAGE} \
    kubectl port-forward svc/vault -n vault 8200:8200

  echo "    Waiting for port-forward to establish..."
  sleep 3

  # Step 3: Unseal Vault
  echo ""
  echo "==> Unsealing Vault..."
  UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' ${POC_DIR}/vault/vault-init.json)
  docker run --rm --network host \
    -e VAULT_ADDR=http://127.0.0.1:8200 \
    -e VAULT_TOKEN=unseal-no-token-needed \
    ${TOOLKIT_IMAGE} \
    vault operator unseal "${UNSEAL_KEY}"

  # Step 4: Run vault-init.sh (near no-op on restarts — re-applies config idempotently)
  echo ""
  echo "==> Running vault-init.sh..."
  bash ${POC_DIR}/scripts/vault-init.sh

  # Step 5: Wait for Elasticsearch
  echo ""
  echo "==> Waiting for Elasticsearch to be healthy..."
  docker run --rm --network host \
    -v ${POC_DIR}/kube:/root/.kube \
    -e KUBECONFIG=/root/.kube/config \
    ${TOOLKIT_IMAGE} \
    kubectl wait --for=condition=ready pod \
      -l elasticsearch.k8s.elastic.co/cluster-name=elasticsearch \
      -n observability --timeout=300s

  # Step 6: Start Gitea Actions runner
  echo ""
  echo "==> Starting Gitea Actions runner..."
  runner-start

  echo ""
  echo "Session ready:"
  echo "  https://whoami.test"
  echo "  https://httpbin.test"
  echo "  https://traefik.test/dashboard/"
  echo "  https://kibana.test"
  echo "  https://gitea.test"
  echo "  https://argocd.test"
  echo ""
  echo "Start port-forwards in dedicated terminals if needed:"
  echo "  pf-vault   — Vault UI (http://<SERVER_IP>:8200)"
  echo "  pf-es      — Elasticsearch API (https://<SERVER_IP>:9200)"
}

poc-stop() {
  # Clean up background port-forward containers and runner
  docker stop pf-vault-bg 2>/dev/null && echo "Vault port-forward stopped" || true
  docker stop pf-es       2>/dev/null && echo "ES port-forward stopped"   || true
  docker stop pf-kibana   2>/dev/null && echo "Kibana port-forward stopped" || true
  docker stop pf-gitea    2>/dev/null && echo "Gitea port-forward stopped" || true
  docker stop pf-argocd   2>/dev/null && echo "ArgoCD port-forward stopped" || true
  runner-stop
}

poc-sync-from-git() {
  # Sync tracked files from the git repo into the working poc directory.
  # Run on your workstation after a git pull to update ~/Projects/poc
  # without touching runtime state (vault/, kube/, tmp/, etc.).
  #
  # Assumes git repo is at ~/Projects/gitops-OpenTelemetry-poc
  # Override with: poc-sync-from-git /path/to/other/repo
  #
  # Usage: poc-sync-from-git
  #        poc-sync-from-git --dry-run

  local git_repo="${1:-${HOME}/Projects/gitops-OpenTelemetry-poc}"
  local dry_run=""

  if [[ "${1:-}" == "--dry-run" ]]; then
    dry_run="--dry-run"
    git_repo="${HOME}/Projects/gitops-OpenTelemetry-poc"
    echo "==> DRY RUN — no files will be changed"
  fi

  if [[ ! -d "${git_repo}/.git" ]]; then
    echo "ERROR: ${git_repo} is not a git repo."
    echo "Usage: poc-sync-from-git [/path/to/repo]"
    return 1
  fi

  echo "==> Syncing from ${git_repo}"
  echo "    to           ${POC_DIR}"
  echo ""

  rsync -av --progress ${dry_run} \
    --exclude='vault/' \
    --exclude='kube/' \
    --exclude='tmp/' \
    --exclude='helm-cache/' \
    --exclude='helm-config/' \
    --exclude='context-history/' \
    --exclude='.git/' \
    --exclude='*.pyc' \
    "${git_repo}/" \
    "${POC_DIR}/"

  echo ""
  echo "==> Sync complete"
  echo "    vault/, kube/, tmp/, helm-cache/ were NOT touched"
}

context-snapshot() {
  # Save a dated snapshot of CONTEXT.md before starting a new phase
  # Usage: context-snapshot <label>
  # Example: context-snapshot phase3-complete
  local label="${1:-checkpoint}"
  local dir=${POC_DIR}/context-history
  local filename="CONTEXT-$(date +%Y%m%d)-${label}.md"

  mkdir -p "${dir}"

  if [[ ! -f ${POC_DIR}/CONTEXT.md ]]; then
    echo "Error: ${POC_DIR}/CONTEXT.md not found"
    return 1
  fi

  cp ${POC_DIR}/CONTEXT.md "${dir}/${filename}"
  echo "Saved: context-history/${filename}"
  echo ""
  echo "History:"
  ls -1 "${dir}/"
}
