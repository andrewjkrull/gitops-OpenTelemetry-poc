# Kubernetes Platform PoC

A local Kubernetes proof-of-concept demonstrating PKI automation, TLS certificate
management, ingress routing, secret management, full-stack observability, and a
complete GitOps workflow using open source tooling.

Built to be reproducible — a colleague with the prerequisites can clone this repo
and have a running environment by following the rebuild runbook.

---

## What this builds

```
Browser / curl
     | HTTPS (Vault-issued certs, 72h TTL, auto-renewed)
     v
k3d (local Kubernetes — 1 control plane, 2 agents)
     |
     v
Traefik v3 (ingress + TLS termination + OTLP telemetry)
     |--► whoami.test        --► whoami pods
     |--► httpbin.test       --► httpbin pod
     |--► traefik.test       --► Traefik dashboard
     |--► kibana.test        --► Kibana (Elastic)
     |--► gitea.test         --► Gitea (Git server + container registry)
     └--► argocd.test        --► ArgoCD (GitOps controller)

Vault (server mode, persistent PKI + secret management)
     |--► cert-manager ClusterIssuer
     |         └── Root CA → Intermediate CA → app certs
     └--► Vault Agent (sidecar injection into app pods)

OTel Collector (DaemonSet + Gateway)
     |-- Traefik traces + metrics
     |-- Application traces (sensor-producer, mqtt-bridge, event-consumer)
     |-- Container logs (all namespaces)
     └--► Elasticsearch 8.x --► Kibana dashboards

Phase 4 — GitOps + Distributed tracing demo:
     Gitea (source of truth) --► ArgoCD (reconciler) --► k3d (cluster)
     sensor-producer --MQTT--► mqtt-bridge --Kafka--► event-consumer
                           └── Redis cache ──────────► Redis results
     (all three services emit OTLP traces — one trace ID spans the full chain)

Messaging layer (messaging namespace):
     Eclipse Mosquitto 2.0  — MQTT broker (SASL auth)
     Redis 7               — deduplication cache (password auth)
     Apache Kafka 3.8.0    — event streaming (KRaft, SASL/PLAIN)
```

---

## Prerequisites

### 1 — WSL2 on Windows (or native Linux)

Built and tested on **WSL2 with Debian Trixie**. Native Linux works identically.
macOS is not tested.

### 2 — Docker Engine (not Docker Desktop)

Docker Engine must be running natively inside WSL2 — not Docker Desktop.

```bash
docker info | grep "Server Version"
```

### 3 — zsh

The shell environment file (`poc-toolkit.zsh`) is zsh-only. Most modern Linux
and macOS systems have it. Verify:

```bash
zsh --version
# If missing: sudo apt-get install -y zsh
```

### 4 — devops-toolkit container image

**This is the most important prerequisite.** Every tool in this project
(`kubectl`, `helm`, `vault`, `k3d`, etc.) runs inside a container image called
`devops-toolkit:latest`. Nothing is installed directly on the host machine.

```bash
# Verify the image is available
docker images devops-toolkit:latest
```

The image is built from the `docker-devops` repository. If you don't have it:

```bash
git clone <docker-devops-repo-url>
cd docker-devops
make build
```

The image must contain these tools at these minimum versions:

| Tool | Minimum version |
|------|----------------|
| kubectl | 1.28+ |
| helm | 3.12+ |
| k3d | 5.7.x |
| vault | 1.15+ |
| jq | 1.6+ |
| openssl | 3.x |

### 5 — /etc/hosts entries

```bash
sudo tee -a /etc/hosts <<EOF
127.0.0.1  whoami.test
127.0.0.1  httpbin.test
127.0.0.1  traefik.test
127.0.0.1  kibana.test
127.0.0.1  gitea.test
127.0.0.1  argocd.test
EOF
```

To access these from a Windows browser, also add them to
`C:\Windows\System32\drivers\etc\hosts` (run PowerShell as Administrator):

```
127.0.0.1 whoami.test
127.0.0.1 httpbin.test
127.0.0.1 traefik.test
127.0.0.1 kibana.test
127.0.0.1 gitea.test
127.0.0.1 argocd.test
```

### 6 — Shell environment configuration

The toolkit environment file wires up all tool aliases and sets the two path
variables that everything else derives from. **It must be sourced before any
commands in this project will work.**

Run the setup script — it handles all of this for you:

```bash
bash scripts/setup.sh
```

The setup script will:
- Verify zsh and Docker are installed
- Ask you to confirm `POC_DIR` (this repo) and `TOOLKIT_DIR` (docker-devops repo)
- Copy `poc-toolkit.zsh` to `~/.zshrc.d/` with the correct paths set
- Wire up sourcing in `~/.zshrc`
- Create the runtime directory structure
- Check that the toolkit image exists

If you prefer to configure manually, open `~/.zshrc.d/poc-toolkit.zsh` after
copying it and set these two variables at the top:

```zsh
export POC_DIR="${HOME}/Projects/poc"          # ← path to this repo
export TOOLKIT_DIR="${HOME}/Projects/docker-devops"  # ← path to docker-devops repo
```

Everything else in the file derives from these two variables.

---

## How the toolkit container works

Every command (`kubectl`, `helm`, `vault`, `k3d`) is an alias that runs the
devops-toolkit container:

```bash
# What 'kubectl get pods' actually runs:
docker run --rm -it --network host \
  -v ~/Projects/poc/manifests:/work \
  -v ~/Projects/poc/kube:/root/.kube \
  devops-toolkit:latest kubectl get pods
```

**What this means in practice:**

- Commands work exactly like normal — `kubectl get pods`, `helm install`, etc.
- Manifest paths in commands use the container mount: always `/work/filename.yaml`,
  not `~/Projects/poc/manifests/filename.yaml`
- Port-forwards (`pf-vault`, `pf-es`) run in dedicated terminal tabs —
  they are long-running container processes, not one-shot commands

**Interactive shell:**

```bash
toolkit
# Drops into bash inside the container with all tools available
```

---

## Directory structure

```
poc/
├── README.md                        <- this file
├── CONTEXT.md                       <- AI session context (gitignored)
├── k3d-registries.yaml              <- containerd registry trust config
├── .gitignore
│
├── documentation/
│   ├── poc-toolkit.zsh              <- shell environment (copy to ~/.zshrc.d/)
│   ├── rebuild-runbook.md           <- Phases 1-4 complete step-by-step build guide
│   ├── troubleshooting-guide.md     <- debugging reference
│   ├── sensor-demo-architecture.md  <- architecture + OTel story + demo script
│   ├── observability-setup.md       <- Phase 5a: Kibana dashboard build runbook
│   ├── platform-demo-playbook.md    <- Phase 5b/5c: latency injection + env promotion
│   ├── gitea-runner-config.yml      <- reference runner config
│   ├── sensor-demo-kibana.ndjson    <- Kibana import scaffold (data views + dashboard shell)
│   └── sensor-demo-kibana-complete.ndjson  <- full Kibana dashboard export (re-importable)
│
├── manifests/                       <- all Kubernetes YAML
│   ├── vault-server-values.yaml
│   ├── vault-clusterissuer.yaml
│   ├── traefik-values.yaml
│   ├── apps.yaml
│   ├── ingress.yaml
│   ├── traefik-dashboard.yaml
│   ├── traefik-dashboard-cert.yaml
│   ├── elasticsearch.yaml
│   ├── kibana.yaml
│   ├── kibana-cert.yaml
│   ├── kibana-transport.yaml
│   ├── kibana-ingressroute.yaml
│   ├── otel-gateway-config.yaml
│   ├── otel-gateway.yaml
│   ├── otel-daemonset-config.yaml
│   ├── otel-daemonset.yaml
│   ├── messaging-namespace.yaml     <- namespaces: messaging, sensor-*, gitea, argocd
│   ├── messaging.yaml               <- Mosquitto, Redis, Kafka
│   ├── gitea-values.yaml            <- Gitea Helm values
│   ├── gitea-cert.yaml              <- TLS cert for gitea.test
│   ├── gitea-ingressroute.yaml      <- Traefik IngressRoute for gitea.test
│   ├── gitea-runner.yaml            <- Gitea Actions runner (reference only — not applied)
│   ├── argocd-values.yaml           <- ArgoCD Helm values
│   ├── argocd-cert.yaml             <- TLS cert for argocd.test
│   └── argocd-ingressroute.yaml     <- Traefik IngressRoute for argocd.test
│
├── scripts/
│   ├── setup.sh                     <- first-time environment setup (start here)
│   ├── generate-ca.sh               <- one-time CA generation (run once per machine)
│   ├── cluster-create.sh            <- creates k3d cluster with CA pre-installed
│   ├── cluster-delete.sh            <- deletes cluster + cleans stale credentials
│   ├── vault-bootstrap.sh           <- one-time Vault init (fresh cluster only)
│   ├── vault-init.sh                <- idempotent PKI/auth/KV setup
│   ├── obs-init.sh                  <- creates ES credentials secret
│   ├── messaging-init.sh            <- generates messaging credentials + Vault KV
│   └── gitea-init.sh                <- creates Gitea org, repos, runner token, ArgoCD creds
│
├── apps/                            <- Phase 4 .NET application source
│   ├── sensor-producer/             <- publishes sensor readings to MQTT
│   ├── mqtt-bridge/                 <- MQTT → Redis dedup → Kafka
│   └── event-consumer/              <- Kafka → processes events
│
└── (gitignored runtime dirs)
    ├── tmp/
    ├── temp/
    ├── kube/
    ├── helm-cache/
    ├── helm-config/
    └── vault/                       <- vault-init.json, root-token, poc-ca.crt, poc-ca.key
```

**ConfigMaps must be applied before their workloads:**

```bash
kubectl apply -f /work/otel-gateway-config.yaml   # ConfigMap first
kubectl apply -f /work/otel-gateway.yaml           # then Deployment
kubectl apply -f /work/otel-daemonset-config.yaml
kubectl apply -f /work/otel-daemonset.yaml
```

---

## Quick start

```bash
# 1. Clone
git clone <repo-url> ~/Projects/poc
cd ~/Projects/poc

# 2. Run setup — configures shell environment, creates directories, checks prerequisites
bash scripts/setup.sh

# 3. Reload shell
source ~/.zshrc

# 4. Build the toolkit image (if not already built)
toolkit-build
# or: cd "${TOOLKIT_DIR}" && make build

# 5. Follow the rebuild runbook
# documentation/rebuild-runbook.md
```

Budget 20–30 minutes for a first build (mostly image pull time).

---

## Session restart (after WSL2 reboot)

```bash
k3d cluster start poc
kubectl get nodes -w   # wait for Ready, Ctrl+C

# Start ES port-forward in a dedicated terminal
pf-es

# poc-start handles everything else:
#   - waits for Vault pod Ready
#   - unseals Vault via port-forward
#   - runs vault-init.sh (near no-op on restarts)
#   - waits for Elasticsearch
#   - starts the Gitea Actions runner
poc-start

# Optional: Vault UI access in a second terminal
pf-vault   # then open http://127.0.0.1:8200
```

---

## Accessing services

| Service | URL | Notes |
|---------|-----|-------|
| Vault UI | http://127.0.0.1:8200 | Requires `pf-vault`. Token: `cat ${POC_DIR}/vault/root-token` |
| Elasticsearch | https://127.0.0.1:9200 | Requires `pf-es` |
| Kibana | https://kibana.test | Password: `es-pass` or Vault UI → secret/observability/elasticsearch |
| Traefik dashboard | https://traefik.test/dashboard/ | |
| Gitea | https://gitea.test | Login: `poc-admin` / `gitea-token` |
| ArgoCD | https://argocd.test | Login: `admin` / `argocd-pass` |
| whoami | https://whoami.test | |
| httpbin | https://httpbin.test | |

Vault is not routed through Traefik — accessible via port-forward only.

---

## Key design decisions

| Decision | Rationale |
|----------|-----------|
| devops-toolkit container | No host tool installation, locked versions, portable across machines |
| `setup.sh` for first-time config | Single script sets `POC_DIR`/`TOOLKIT_DIR`, copies toolkit file, creates dirs |
| Vault server mode + file storage | PKI and secrets persist across pod restarts |
| Vault Agent sidecar injection | Apps never touch k8s Secrets API — every credential access is audited in Vault |
| Explicit Vault unseal via port-forward | In-pod unseal deadlocks — Vault must be running before it can be unsealed |
| Gitea as Git server + container registry | Single tool replaces both GitHub and a standalone registry |
| ArgoCD for GitOps | One Application per environment — dev auto-syncs, qa/prod manual |
| Kustomize overlays | base + dev/qa/prod — same manifests, different configs per environment |
| Gitea Actions runner on WSL2 host | k3d nodes don't expose Docker socket — runner must run on the host |
| W3C traceparent in message envelopes | Standard context propagation across MQTT and Kafka without HTTP |
| k3d over minikube | Multi-node cluster tests real scheduling and Secret access patterns |
| Traefik over Envoy Gateway | Simpler ops model while learning the org's platform patterns |
| ECK over raw Helm | Production fidelity — ECK manages lifecycle, TLS, and upgrades |
| OTel Collector as ingestion layer | Backend-agnostic — swap ES for another backend without changing apps |
| Single ES node | PoC only — production uses 3 nodes with proper replica allocation |

---

## Known quirks

- **Vault port-forward must run via `pf-vault` alias** — not inside a `toolkit` shell
- **k3d loadbalancer must NOT have port 8200 mapped** — conflicts with pf-vault
- **Vault liveness probe requires `uninitcode=204&sealedcode=204`** — otherwise the pod is killed before `operator init` can run
- **cert-manager uses `crds.enabled=true`** — `installCRDs` is deprecated
- **Traefik OTel requires `additionalArguments`** — the `tracing:` Helm values key is silently ignored in chart 39.0.5
- **Kibana uses IngressRoute CRD** — standard Ingress is unreliable in Traefik v3
- **k3d kubelet port 10250 returns 401** — OTel uses port 10255 (read-only, no auth)
- **ES password from Vault CLI adds ANSI codes** — use `es-pass` function or `kubectl get secret` directly
- **Vault CLI token helper conflicts with `/root/.vault` mount** — scripts must not mount the vault dir and must pass `VAULT_TOKEN` explicitly
- **Gitea Actions runner runs on WSL2 host, not in k3d** — k3d nodes do not expose the Docker socket; runner is managed via `runner-start` / `runner-stop`
- **MQTT and Kafka don't carry HTTP headers** — trace context is carried in the message JSON envelope (`traceParent` field)
- **messaging-init.sh must run before messaging.yaml** — creates the Kubernetes Secrets that the workloads reference

---

## Versions

| Component | Version |
|-----------|---------|
| k3d | 5.7.5 |
| Vault | 1.21.2 |
| cert-manager | v1.20.0 |
| Traefik | v3.6.10 (Helm chart 39.0.5) |
| Elasticsearch | 8.17.0 |
| Kibana | 8.17.0 |
| OTel Collector Contrib | 0.123.0 |
| Gitea | 1.25.4 (Helm chart 12.5.0) |
| ArgoCD | latest (argo/argo-cd Helm chart) |
| Eclipse Mosquitto | 2.0 |
| Redis | 7-alpine |
| Apache Kafka | 3.8.0 |
| .NET runtime | 6.0 |
| kubectl | 1.34.1 |
| helm | 3.19.0 |
