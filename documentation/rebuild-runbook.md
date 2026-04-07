# Kubernetes PoC — Rebuild Runbook

A complete build guide covering Phases 1–4: PKI + Ingress, Observability,
Vault Secret Management, and GitOps Application Deployments.

---

## Architecture overview

This platform runs on a **dedicated Linux host** (bare metal or VM) with native
Docker Engine. A k3d cluster runs inside Docker. All commands originate on the
Linux host — your workstation is used only for browser access to the `.test` URLs.

```
Workstation (Windows/Linux)
  └── browser → .test URLs → server IP → Traefik → cluster services
  └── SSH → Linux host → all commands run here

Linux host (devajk01)
  └── Docker Engine
      └── k3d cluster (k3d-poc-server-0, k3d-poc-agent-0, k3d-poc-agent-1)
          └── Vault, cert-manager, Traefik, ECK, OTel, Gitea, ArgoCD, apps
```

> **If you already have a Kubernetes cluster:** skip the k3d cluster creation
> steps (Step 2 and cluster-create.sh). Substitute your own kubeconfig into
> `${POC_DIR}/kube/config`. Everything from Vault bootstrap onward applies
> identically. Note that the CoreDNS patch for `gitea.test` will need to be
> applied manually to match your cluster's DNS setup.

---

## Pre-flight checklist


### Terminal multiplexer (recommended)

Several steps in this runbook require port-forwards running in dedicated
terminals — Vault and Elasticsearch must stay open for the duration of a
session. A terminal multiplexer lets you manage multiple persistent sessions
in a single SSH connection without losing work if the connection drops.

**tmux** (recommended):
- Install: `sudo apt-get install -y tmux`
- Quick reference: https://tmuxcheatsheet.com

**GNU Screen** (alternative):
- Install: `sudo apt-get install -y screen`
- Quick reference: https://opensource.com/downloads/gnu-screen-cheat-sheet

Suggested tmux layout for a build session:

```
window 0: main shell     — run all commands here
window 1: pf-vault       — Vault port-forward (leave running)
window 2: pf-es          — Elasticsearch port-forward (leave running)
```

Basic tmux commands:
```bash
tmux new -s poc          # start a new session named poc
Ctrl+b c                 # create a new window
Ctrl+b n                 # next window
Ctrl+b p                 # previous window
Ctrl+b d                 # detach (session keeps running)
tmux attach -t poc       # reattach later
```

> If your SSH connection drops, reattach with `tmux attach -t poc` and all
> windows will be exactly as you left them — port-forwards still running.

### SSH key setup (required for poc-sync-push / poc-sync-pull)

If you edit files on a workstation and sync them to the server, set up
passwordless SSH first — rsync will prompt for a password on every sync without it.

```bash
# On your workstation — generate a key if you don't have one
ssh-keygen -t ed25519 -C "poc-sync"

# Copy your public key to the server
ssh-copy-id your-user@devajk01

# Verify it works without a password prompt
ssh your-user@devajk01 echo "SSH key working"
```

### Shell environment

The toolkit environment must be in place and sourced before any commands in
this runbook will work.

```bash
# On the Linux host — copy the toolkit to your shell config
mkdir -p ~/.zshrc.d
cp ~/Projects/poc/documentation/poc-toolkit.zsh ~/.zshrc.d/poc-toolkit.zsh

# Wire up sourcing in ~/.zshrc if not already present
grep -q 'zshrc.d' ~/.zshrc \
  || echo 'for f in ~/.zshrc.d/*.zsh; do source "$f"; done' >> ~/.zshrc

# Reload
source ~/.zshrc

# Verify toolkit aliases are active
type kubectl | head -1
# Expected: kubectl is an alias for docker run ...
```

**Before reloading, open `~/.zshrc.d/poc-toolkit.zsh` and configure the
variables at the top:**

```zsh
export POC_DIR="${HOME}/Projects/poc"             # path to this repo
export TOOLKIT_DIR="${HOME}/Projects/docker-devops" # path to docker-devops repo
export POC_SERVER="your-user@devajk01"            # for poc-sync-push/pull
export POC_SERVER_DIR="~/Projects/poc"            # poc dir path on the server
```

### /etc/hosts entries on the Linux host

These entries must exist on the Linux host before the cluster is built.
Traefik listens on ports 80/443 on the host and routes by hostname.

```bash
# Check if entries already exist
grep -E "whoami|httpbin|traefik|kibana|gitea|argocd" /etc/hosts
```

If any are missing:

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

> **vault.test is intentionally omitted** — Vault is not routed through
> Traefik. Access it via port-forward at `http://<SERVER_IP>:8200`.

### /etc/hosts entries on your workstation

On Windows (PowerShell as Administrator) — replace `<SERVER_IP>` with your
server's actual IP address:

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value `
  "`n<SERVER_IP> whoami.test`n<SERVER_IP> httpbin.test`n<SERVER_IP> traefik.test`n<SERVER_IP> kibana.test`n<SERVER_IP> gitea.test`n<SERVER_IP> argocd.test"
```

On Linux workstation:

```bash
echo "<SERVER_IP>  whoami.test httpbin.test traefik.test kibana.test gitea.test argocd.test" \
  | sudo tee -a /etc/hosts
```

### Toolkit image

The `devops-toolkit:latest` image is built from the `docker-devops` repository.

```bash
# Clone the docker-devops repo if not already present
# Note: this repo is not yet public — it will be available at:
# https://github.com/andrewjkrull/docker-devops
git clone https://github.com/andrewjkrull/docker-devops "${TOOLKIT_DIR}"

# Build the image
cd "${TOOLKIT_DIR}" && make build

# Verify the image is available
docker images devops-toolkit:latest
```

> The toolkit image must be built before any commands in this runbook will
> work — all `kubectl`, `helm`, `vault`, and other tool invocations run
> through it via the shell aliases in `poc-toolkit.zsh`. The `toolkit-build`
> shell function is a shortcut once the environment is sourced.

### Create runtime directories

Runtime directories are excluded from sync and not committed to git — create
them explicitly after a fresh clone or sync:

```bash
poc-dirs
```

This creates: `manifests/`, `tmp/`, `kube/`, `helm-cache/`, `helm-config/`,
`vault/`, `documentation/`, `scripts/`, `context-history/`, and the `apps/`
subdirectories.

> **Permissions note:** the toolkit container runs as root inside Docker.
> Files written into runtime directories by toolkit commands (kubeconfig,
> Helm cache, tmp files) will be owned by root on the host. The scripts that
> need it handle this with `sudo chown` automatically — `cluster-create.sh`
> does this for `kube/config` for example. If you ever hit a permission denied
> error on a file in a runtime directory, fix it with:
> ```bash
> sudo chown -R $(id -u):$(id -g) \
>   ${POC_DIR}/vault \
>   ${POC_DIR}/kube \
>   ${POC_DIR}/tmp \
>   ${POC_DIR}/helm-cache \
>   ${POC_DIR}/helm-config
> ```

### CA certificate (one-time per machine)

The PoC uses a pre-generated CA cert that persists across all cluster rebuilds.
Generate it once on this machine — it lives in `${POC_DIR}/vault/` (gitignored).

```bash
# Check if already generated
if ls ${POC_DIR}/vault/poc-ca.crt ${POC_DIR}/vault/poc-ca.key 2>/dev/null; then
  echo "CA exists — skip this step"
else
  bash ${POC_DIR}/scripts/generate-ca.sh
fi
```

`generate-ca.sh` generates the CA, installs it into the host trust store, and
restarts Docker. This is the only time Docker needs to restart for CA trust —
every subsequent cluster rebuild reuses the same CA.

> **Important:** `vault/poc-ca.crt` and `vault/poc-ca.key` must never be
> overwritten by a sync from your workstation. The `poc-sync-push` and
> `poc-sync-pull` functions exclude the `vault/` directory for this reason.
> If you accidentally delete the CA, run `generate-ca.sh` again and reinstall
> the new cert in your browser and workstation trust store.

### Confirm scripts are in place and executable

```bash
ls ${POC_DIR}/scripts/*.sh
chmod +x ${POC_DIR}/scripts/*.sh
```

---

## Phase 1 — PKI and Ingress

### Step 1 — Create the cluster

```bash
bash ${POC_DIR}/scripts/cluster-create.sh
```

This script:
1. Verifies the CA cert exists
2. Creates the k3d cluster (1 server, 2 agents) with all port mappings
3. Mounts the CA cert into every node at creation time
4. Merges the kubeconfig and fixes the `0.0.0.0` address

> **Note:** CoreDNS patching for `gitea.test` is a separate step that runs
> after Traefik is installed. See Step 8b.

> **Expected warnings — not errors:** k3d will warn about failing to stat
> volume mount paths. This is because cluster-create.sh runs k3d inside a
> container which cannot stat host paths. The Docker daemon can access them
> and the mounts succeed.

Expected output ends with:

```
[cluster-create] all nodes Ready
[cluster-create] k3d-poc-server-0: poc-ca.crt present
[cluster-create] k3d-poc-agent-0: poc-ca.crt present
[cluster-create] k3d-poc-agent-1: poc-ca.crt present
[cluster-create] cluster-create.sh complete
```

### Step 2 — Namespaces

```bash
kubectl create namespace vault
kubectl create namespace cert-manager
kubectl create namespace traefik
kubectl create namespace apps
kubectl create namespace observability

kubectl label namespace vault         purpose=infrastructure
kubectl label namespace cert-manager  purpose=infrastructure
kubectl label namespace traefik       purpose=infrastructure
kubectl label namespace apps          purpose=workloads
kubectl label namespace observability purpose=observability
```

### Step 3 — Helm repositories

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo add jetstack  https://charts.jetstack.io
helm repo add traefik   https://traefik.github.io/charts
helm repo add elastic   https://helm.elastic.co
helm repo update
```

### Step 4 — Vault

#### 4a — Install via Helm

```bash
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  --values /work/vault-server-values.yaml
```

Watch the pod — it will be `Running` but `0/1` Ready (sealed and uninitialized).
That is expected at this stage.

```bash
kubectl get pods -n vault -w
# Expected: vault-0   0/1   Running   — Ctrl+C
```

#### 4b — Start pf-vault port-forward

Open a **dedicated terminal** and leave it running for the entire session:

```bash
pf-vault
# Expected: Forwarding from 127.0.0.1:8200 -> 8200
```

Verify the API is reachable:

```bash
curl http://127.0.0.1:8200/v1/sys/health
# Expected: HTTP 501 (uninitialized) — correct at this stage
```

#### 4c — Bootstrap Vault

```bash
bash ${POC_DIR}/scripts/vault-bootstrap.sh
```

This initialises Vault, saves the unseal key and root token to `${POC_DIR}/vault/`
(gitignored), stores the unseal key in a Kubernetes Secret, and unseals Vault.

Expected output ends with:

```
============================================================
  vault-bootstrap.sh complete
============================================================
  Init data:   .../vault/vault-init.json
  Root token:  .../vault/root-token
  Next: run vault-init.sh
============================================================
```

> **Vault UI:** `http://<SERVER_IP>:8200`
> Token: `cat ${POC_DIR}/vault/root-token`
> Not routed through Traefik by design.

### Step 5 — cert-manager

```bash
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set crds.enabled=true \
  --set "extraArgs={--enable-certificate-owner-ref=true}"

kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/instance=cert-manager \
  -n cert-manager --timeout=120s

kubectl get pods -n cert-manager
```

Expected — three pods Running:

```
cert-manager-<hash>              1/1  Running
cert-manager-cainjector-<hash>   1/1  Running
cert-manager-webhook-<hash>      1/1  Running
```

### Step 6 — Vault PKI init

```bash
bash ${POC_DIR}/scripts/vault-init.sh
```

On a fresh cluster this configures:
- Imports the pre-generated CA into Vault PKI
- Creates intermediate CA and cert-manager PKI role
- Enables Kubernetes auth
- Creates all Vault policies and auth roles
- KV v2 secrets engine at `secret/`

On subsequent restarts it is a near no-op — skips already-configured sections
and just updates the Kubernetes auth config.

### Step 7 — ClusterIssuer

```bash
kubectl apply -f /work/vault-clusterissuer.yaml

kubectl get clusterissuer vault-issuer -o wide
# Wait for READY: True — may take 15-20s
```

### Step 8 — Traefik

```bash
helm install traefik traefik/traefik \
  --namespace traefik \
  --values /work/traefik-values.yaml

kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=traefik \
  -n traefik --timeout=120s
```

Verify OTel args are present:

```bash
kubectl get pod -n traefik -l app.kubernetes.io/name=traefik \
  -o jsonpath='{.items[0].spec.containers[0].args}' \
  | tr ',' '\n' | grep -i otlp
# Expected: 8 lines with tracing and metrics OTLP endpoint flags
```

### Step 8b — CoreDNS patch for gitea.test

Now that Traefik is installed, patch CoreDNS to resolve `gitea.test` inside
the cluster. This is required for the Gitea Actions runner job containers to
reach the Gitea registry for `docker login`, `docker push`, and `git clone`.

```bash
bash ${POC_DIR}/scripts/coredns-patch.sh
```

This does two things:

1. Adds a rewrite rule to the CoreDNS Corefile pointing `gitea.test` at
   `traefik.traefik.svc.cluster.local`. Traefik routes by `Host` header to
   the Gitea service. The Corefile survives node restarts.

2. Adds `gitea.test → Traefik ClusterIP` to each k3d node's `/etc/hosts`.
   containerd on k3d nodes uses the node's hosts file (not cluster DNS) when
   pulling images — this entry is required for `gitea.test/poc/<app>:<sha>`
   image pulls to succeed. This entry is ephemeral and lost on node restart —
   re-run `coredns-patch.sh` after any cluster restart.

Expected output ends with:

```
[coredns-patch] CoreDNS rewrite added — gitea.test → traefik.traefik.svc.cluster.local
[coredns-patch] k3d-poc-server-0: added gitea.test → <TRAEFIK_CLUSTERIP>
[coredns-patch] k3d-poc-agent-0: added gitea.test → <TRAEFIK_CLUSTERIP>
[coredns-patch] k3d-poc-agent-1: added gitea.test → <TRAEFIK_CLUSTERIP>
[coredns-patch] CoreDNS restarted and ready
[coredns-patch] Rewrite rule confirmed
[coredns-patch] coredns-patch.sh complete

  gitea.test → traefik.traefik.svc.cluster.local (<TRAEFIK_CLUSTERIP>)
```

Verify from inside the cluster:

```bash
kubectl run dns-test --rm -it --restart=Never   --image=busybox:1.36 -- nslookup gitea.test
# Expected: Address: <TRAEFIK_CLUSTERIP>
```

### Step 9 — Test apps and ingress

```bash
kubectl apply -f /work/apps.yaml

kubectl wait --for=condition=ready pod \
  -l app=whoami -n apps --timeout=120s

kubectl apply -f /work/ingress.yaml
kubectl apply -f /work/traefik-dashboard-cert.yaml
kubectl apply -f /work/traefik-dashboard.yaml

kubectl get certificate -n apps -w
# Ctrl+C when both show READY: True
```

### Phase 1 smoke test

```bash
curl -sk https://whoami.test | grep Hostname
curl -sk https://httpbin.test/get | jq .url
curl -sk -o /dev/null -w "%{http_code}" https://traefik.test/dashboard/
# Expected: hostname output, URL, 200

# Verify cert is Vault-issued
kubectl get secret whoami-tls -n apps \
  -o jsonpath='{.data.tls\.crt}' \
  | base64 -d \
  | openssl x509 -noout -text \
  | grep "Issuer:"
# Expected: CN=poc-intermediate-ca
```

---

## Phase 2 — Observability

### Step 10 — ECK operator

```bash
helm install elastic-operator elastic/eck-operator \
  --namespace elastic-system \
  --create-namespace \
  --set managedNamespaces='{observability}'

kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=elastic-operator \
  -n elastic-system \
  --timeout=120s
```

### Step 11 — Elasticsearch

```bash
kubectl apply -f /work/elasticsearch.yaml

kubectl get elasticsearch -n observability -w
# Ctrl+C when HEALTH: green and PHASE: Ready — takes 2-3 minutes on first pull
```

### Step 12 — Kibana

```bash
kubectl apply -f /work/kibana.yaml

kubectl get kibana -n observability -w
# Ctrl+C when HEALTH: green
```

### Step 13 — ES port-forward and credential sync

Open a **dedicated terminal** and leave it running:

```bash
pf-es
# Expected: Forwarding from 127.0.0.1:9200 -> 9200
```

Sync the Elasticsearch password into Vault now that ES is deployed:

```bash
bash ${POC_DIR}/scripts/vault-init.sh
```

Verify:

```bash
ES_PASS=$(kubectl get secret elasticsearch-es-elastic-user \
  -n observability -o jsonpath='{.data.elastic}' | base64 -d | tr -d '\r\n')

curl -sk -u "elastic:${ES_PASS}" \
  "https://127.0.0.1:9200/_cluster/health" | jq .status
# Expected: "green"
```

> **Note on password retrieval:** always pull the ES password from the k8s
> secret for scripting — the Vault CLI adds ANSI escape codes that corrupt
> values in shell variables. Use `es-pass` or the pattern above. Use the
> Vault UI copy button for manual retrieval.

### Step 14 — OTel index templates, ILM, and credentials

> **Critical:** run `obs-init` BEFORE deploying the OTel collectors.
> If collectors start writing before templates exist, Elasticsearch creates
> data streams with auto-mapped schemas that conflict with subsequent writes.

Requires `pf-vault` and `pf-es` running in dedicated terminals.

```bash
bash ${POC_DIR}/scripts/obs-init.sh
bash ${POC_DIR}/scripts/obs-ilm-init.sh
```

Expected output ends with:

```
[HH:MM:SS] All 3 templates verified
[HH:MM:SS] otel-es-credentials secret recreated
[HH:MM:SS] OTel collectors not yet deployed — skipping restart
[HH:MM:SS] Observability init complete.
...
[HH:MM:SS] ILM policy poc-2h-delete verified
[HH:MM:SS] ILM retention init complete.
```

> The "OTel collectors not yet deployed" warning is expected — collectors
> are deployed in the next step.

### Step 15 — OTel Collectors

Apply ConfigMaps **before** workloads:

```bash
kubectl apply -f /work/otel-gateway-config.yaml
kubectl apply -f /work/otel-daemonset-config.yaml

kubectl apply -f /work/otel-gateway.yaml
kubectl apply -f /work/otel-daemonset.yaml

kubectl wait --for=condition=ready pod \
  -l app=otel-collector-gateway \
  -n observability \
  --timeout=120s

kubectl get pods -n observability
```

Expected:

```
elasticsearch-es-default-0          1/1  Running
kibana-kb-<hash>                    1/1  Running
otel-collector-daemonset-<hash>     1/1  Running  (×3)
otel-collector-gateway-<hash>       1/1  Running
```

### Step 16 — Kibana TLS and IngressRoute

```bash
kubectl apply -f /work/kibana-cert.yaml
kubectl apply -f /work/kibana-transport.yaml
kubectl apply -f /work/kibana-ingressroute.yaml

kubectl get certificate -n observability -w
# Ctrl+C when kibana-tls shows READY: True
```

### Phase 2 smoke test

```bash
sleep 30   # let collectors start writing

# Generate traffic to populate all three data streams
for i in $(seq 1 10); do curl -sk https://whoami.test > /dev/null; done
for i in $(seq 1 10); do curl -sk https://httpbin.test > /dev/null; done

ES_PASS=$(kubectl get secret elasticsearch-es-elastic-user \
  -n observability -o jsonpath='{.data.elastic}' | base64 -d | tr -d '\r\n')

curl -sk -u "elastic:${ES_PASS}" \
  "https://127.0.0.1:9200/_cat/indices?v&s=index&h=index,health,docs.count" \
  | grep "generic.otel"
# Expected: all three data streams green with docs

curl -sk -o /dev/null -w "%{http_code}" https://kibana.test
# Expected: 302
```

---

## Kibana setup

### Log in

1. Open `https://kibana.test`
2. Username: `elastic`
3. Password: from Vault UI (`http://<SERVER_IP>:8200` → secret → observability → elasticsearch)
   or run `es-pass`

### Create data views

Navigate to **Stack Management** → **Data Views** → **Create data view**

| Name | Index pattern | Timestamp field |
|------|--------------|----------------|
| OTel Logs | `logs-generic.otel-default` | `@timestamp` |
| OTel Metrics | `metrics-generic.otel-default` | `@timestamp` |
| OTel Traces | `traces-generic.otel-default` | `@timestamp` |

---

## Phase 4 — GitOps and Application Deployments

> Phase 3 (Vault Server Mode) is already covered by Steps 4 and 6 above —
> Vault runs in server mode from the start and vault-init.sh configures all
> auth roles and policies needed for Phase 4.

### Step 17 — Phase 4 namespaces and Helm repos

```bash
kubectl apply -f /work/messaging-namespace.yaml
# Creates: messaging, sensor-dev, sensor-qa, sensor-prod, gitea, argocd

kubectl get namespaces | grep -E "messaging|sensor|gitea|argocd"

helm repo add gitea-charts https://dl.gitea.com/charts/
helm repo add argo          https://argoproj.github.io/argo-helm
helm repo update
```

### Step 18 — Messaging infrastructure

#### 18a — Generate credentials

```bash
bash ${POC_DIR}/scripts/messaging-init.sh
```

Expected output ends with:

```
[messaging-init] messaging-init.sh complete

  Kubernetes Secrets created:
    messaging/mosquitto-passwd
    messaging/redis-password
    messaging/kafka-jaas

  Vault KV entries written:
    secret/apps/mqtt
    secret/apps/redis
    secret/apps/kafka
```

Verify secrets exist before deploying:

```bash
kubectl get secret -n messaging
# Expected: mosquitto-passwd, redis-password, kafka-jaas all present
```

#### 18b — Deploy workloads

```bash
kubectl apply -f /work/messaging.yaml

kubectl get pods -n messaging -w
# Ctrl+C when all three show 1/1 Running — Kafka takes 2-3 minutes on first pull
```

Expected:

```
kafka-<hash>       1/1  Running
mosquitto-<hash>   1/1  Running
redis-<hash>       1/1  Running
```

### Step 19 — Gitea admin secret

This must exist before Helm installs Gitea — creating it after causes a
crash-loop requiring uninstall and reinstall.

```bash
GITEA_PASS=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)

kubectl create secret generic gitea-admin-secret \
  -n gitea \
  --from-literal=username="poc-admin" \
  --from-literal=password="${GITEA_PASS}" \
  --from-literal=secretKey="$(openssl rand -base64 32)"

echo "Gitea admin password: ${GITEA_PASS}"
```

> Write this password down. It is retrievable later via `gitea-token` but
> you need it for the first login.

### Step 20 — Gitea

#### 20a — Install via Helm

```bash
helm upgrade --install gitea gitea-charts/gitea \
  --namespace gitea \
  --values /work/gitea-values.yaml
```

Watch the rollout:

```bash
kubectl get pods -n gitea -w
# Ctrl+C when gitea-<hash> shows 1/1 Running
```

Expected:

```
gitea-<hash>                  1/1  Running
gitea-postgresql-0            1/1  Running
gitea-valkey-cluster-0/1/2    1/1  Running
```

#### 20b — TLS and IngressRoute

```bash
kubectl apply -f /work/gitea-cert.yaml

kubectl get certificate -n gitea -w
# Ctrl+C when gitea-tls shows READY: True

kubectl apply -f /work/gitea-ingressroute.yaml

# From the Linux host
curl -sk -o /dev/null -w "%{http_code}" https://gitea.test
# Expected: 200

# From your workstation browser — https://gitea.test
# Expected: Gitea login page
```

### Step 21 — vault-init.sh update

```bash
bash ${POC_DIR}/scripts/vault-init.sh
```

This syncs the Gitea admin password to Vault and applies Phase 4 app auth roles.

### Step 22 — ArgoCD

#### 22a — Install via Helm

```bash
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --values /work/argocd-values.yaml \
  --wait --timeout=5m

kubectl get pods -n argocd
# Expected: all pods 1/1 Running
```

#### 22b — TLS and IngressRoute

```bash
kubectl apply -f /work/argocd-cert.yaml

kubectl get certificate -n argocd -w
# Ctrl+C when argocd-tls shows READY: True

kubectl apply -f /work/argocd-ingressroute.yaml

# From the Linux host
curl -sk -o /dev/null -w "%{http_code}" https://argocd.test
# Expected: 200

# From your workstation browser — https://argocd.test
# Expected: ArgoCD login page
```

#### 22c — Sync ArgoCD password to Vault

```bash
bash ${POC_DIR}/scripts/vault-init.sh
# Watch for: [vault-init] ArgoCD password synced to Vault
```

Verify login:

```bash
argocd-pass   # copy this password
# Open https://argocd.test — login: admin / <password>
```

### Step 23 — Gitea init and host runner

#### 23a — Run gitea-init.sh

Creates the `poc` org, all four repos, the runner registration token, the
ArgoCD repository credential, and image pull secrets in each sensor namespace.

```bash
bash ${POC_DIR}/scripts/gitea-init.sh
```

Expected output ends with:

```
[gitea-init] gitea-init.sh complete

  Org:   https://gitea.test/poc
  Repos:
    https://gitea.test/poc/sensor-producer
    https://gitea.test/poc/mqtt-bridge
    https://gitea.test/poc/event-consumer
    https://gitea.test/poc/sensor-demo-deploy

  Runner token stored in: kubectl get secret gitea-runner-token -n gitea
  ArgoCD creds stored in: kubectl get secret gitea-argocd-creds -n argocd
  Registry pull secrets:  gitea-registry in sensor-dev, sensor-qa, sensor-prod

  Next: start the host Gitea Actions runner
    runner-start
```

Verify the ArgoCD credential is labelled correctly:

```bash
kubectl get secret gitea-argocd-creds -n argocd \
  -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}'
# Expected: repository
```

#### 23b — Start the host runner

The Gitea Actions runner runs as a Docker container **on the Linux host**, not
inside the cluster. An in-cluster DinD approach was attempted and abandoned —
k3d nodes are themselves Docker containers, which causes job containers to lose
internet access and be unable to reach the Docker daemon. The host container
pattern solves this cleanly:

- `network: host` — job containers get full host network (real internet, `gitea.test` via `/etc/hosts`)
- `/var/run/docker.sock` mounted — job containers can run `docker build` directly
- `/etc/hosts` mounted — job containers resolve `gitea.test` without cluster DNS
- PoC CA cert mounted — job containers trust Vault-issued TLS for `git clone` and `curl`

On a fresh cluster build, remove any leftover container from the previous cluster
first — a stale runner registration token will cause registration failure:

```bash
docker rm gitea-runner 2>/dev/null || true
runner-start
```

Check the runner logs to confirm registration:

```bash
docker logs gitea-runner --tail=20
# Expected: Runner registered successfully
```

Verify runner registration in the Gitea UI:

1. Open `https://gitea.test`
2. Sign in as `poc-admin`
3. Navigate to `poc` org → **Settings** → **Actions** → **Runners**
4. `poc-runner` should appear with status **Idle**

> **If the runner shows Offline:** re-run `gitea-init.sh` to get a fresh
> token, remove the old container, and restart:
> ```bash
> bash ${POC_DIR}/scripts/gitea-init.sh
> runner-stop
> docker rm gitea-runner
> runner-start
> ```

### Step 24 — Deploy repo and ArgoCD Applications

#### 24a — Configure git identity

```bash
git config --global user.email
git config --global user.name
# If either is empty, set them:
git config --global user.email "you@example.com"
git config --global user.name "Your Name"
```

#### 24b — Populate the deploy repo

```bash
bash ${POC_DIR}/scripts/deploy-repo-init.sh
```

Expected output ends with:

```
[deploy-repo-init] pushed to https://gitea.test/poc/sensor-demo-deploy
[deploy-repo-init] deploy-repo-init.sh complete
```

Verify the structure in the Gitea UI at `https://gitea.test/poc/sensor-demo-deploy` —
`base/` and `envs/` directories should appear on the `main` branch.

#### 24c — Apply ArgoCD Applications

```bash
kubectl apply -f /work/argocd-app-dev.yaml
kubectl apply -f /work/argocd-app-qa.yaml
kubectl apply -f /work/argocd-app-prod.yaml

kubectl get applications -n argocd -w
# Ctrl+C when sensor-demo-dev shows Synced and Healthy
# qa and prod will show OutOfSync — this is correct, they require manual sync
```

Verify pods in sensor-dev — the busybox standin has no entrypoint so the app
container will crash-loop. This is expected at this stage — the Vault agent
sidecar starts correctly but the pod shows `1/2` until CI deploys real images
in Step 26.

```bash
kubectl get pods -n sensor-dev
# Expected: 3 pods, 1/2 CrashLoopBackOff — correct, CI fixes this in Step 26
```

### Step 25 — CI secrets

These secrets are available to all workflows in the `poc` org:

```bash
GITEA_PASS=$(gitea-token)

# Registry credentials
docker run --rm --network host devops-toolkit:latest \
  curl -sk -X PUT \
  -u "poc-admin:${GITEA_PASS}" \
  -H "Content-Type: application/json" \
  "https://gitea.test/api/v1/orgs/poc/actions/secrets/REGISTRY_USER" \
  -d '{"data":"poc-admin"}'

docker run --rm --network host devops-toolkit:latest \
  curl -sk -X PUT \
  -u "poc-admin:${GITEA_PASS}" \
  -H "Content-Type: application/json" \
  "https://gitea.test/api/v1/orgs/poc/actions/secrets/REGISTRY_PASSWORD" \
  -d "{\"data\":\"${GITEA_PASS}\"}"

# Deploy token for CI to commit image tags to sensor-demo-deploy
# Delete first to ensure idempotency — 404 on a fresh build is expected and harmless
docker run --rm --network host devops-toolkit:latest \
  curl -sk -X DELETE \
  -u "poc-admin:${GITEA_PASS}" \
  "https://gitea.test/api/v1/users/poc-admin/tokens/ci-deploy"
# Expected: {"message":"not found"} on first run — this is fine

DEPLOY_TOKEN=$(docker run --rm --network host devops-toolkit:latest \
  curl -sk -X POST \
  -u "poc-admin:${GITEA_PASS}" \
  -H "Content-Type: application/json" \
  "https://gitea.test/api/v1/users/poc-admin/tokens" \
  -d '{"name":"ci-deploy","scopes":["write:repository","read:repository"]}' \
  | docker run --rm -i devops-toolkit:latest jq -r '.sha1')

docker run --rm --network host devops-toolkit:latest \
  curl -sk -X PUT \
  -u "poc-admin:${GITEA_PASS}" \
  -H "Content-Type: application/json" \
  "https://gitea.test/api/v1/orgs/poc/actions/secrets/CI_DEPLOY_TOKEN" \
  -d "{\"data\":\"${DEPLOY_TOKEN}\"}"

# Verify all three secrets exist
docker run --rm --network host devops-toolkit:latest \
  curl -sk -u "poc-admin:${GITEA_PASS}" \
  "https://gitea.test/api/v1/orgs/poc/actions/secrets" \
  | docker run --rm -i devops-toolkit:latest jq -r '.[].name'
# Expected: CI_DEPLOY_TOKEN, REGISTRY_PASSWORD, REGISTRY_USER
```



### Step 26 — Build and push app images

#### 26a — Verify source files

```bash
find ${POC_DIR}/apps -name "Program.cs" | sort
find ${POC_DIR}/apps -name "Dockerfile" | sort
# Expected: three of each
```

#### 26b — Build locally

```bash
cd ${POC_DIR}/apps/sensor-producer
docker build -t gitea.test/poc/sensor-producer:test .

cd ${POC_DIR}/apps/mqtt-bridge
docker build -t gitea.test/poc/mqtt-bridge:test .

cd ${POC_DIR}/apps/event-consumer
docker build -t gitea.test/poc/event-consumer:test .
```

Each build should complete with no errors. Images are ~200MB.

#### 26c — Push app source to Gitea and trigger CI

```bash
bash ${POC_DIR}/scripts/app-repos-init.sh
```

This push triggers the first CI build in each repo. Watch the Actions tabs:

```
https://gitea.test/poc/sensor-producer/actions
https://gitea.test/poc/mqtt-bridge/actions
https://gitea.test/poc/event-consumer/actions
```

Each workflow:
1. Checkout source
2. Install CA certificate (`update-ca-certificates`) — required for git and curl to trust `gitea.test`
3. Build image via `docker build` using the host Docker socket
4. Push to `gitea.test/poc/<app>:<sha>`
5. Clone deploy repo, update image tag with `sed`, push → ArgoCD detects change and syncs

After all three builds complete and ArgoCD syncs:

```bash
kubectl get pods -n sensor-dev
# Expected: 3 pods, all 2/2 Running with real images

kubectl get pods -n sensor-dev \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# Expected: gitea.test/poc/<app>:<sha> for each
```

### Phase 4 smoke test

```bash
echo "=== ARGOCD APPLICATIONS ==="
kubectl get applications -n argocd

echo ""
echo "=== PODS sensor-dev ==="
kubectl get pods -n sensor-dev

echo ""
echo "=== VAULT SECRETS ==="
for APP in sensor-producer mqtt-bridge event-consumer; do
  echo "--- ${APP} ---"
  kubectl exec -n sensor-dev \
    $(kubectl get pod -n sensor-dev -l app=${APP} \
      -o jsonpath='{.items[0].metadata.name}') \
    -c ${APP} -- ls /vault/secrets/
done

echo ""
echo "=== TRACE CHAIN ==="
kubectl logs -n sensor-dev \
  $(kubectl get pod -n sensor-dev -l app=sensor-producer \
    -o jsonpath='{.items[0].metadata.name}') \
  -c sensor-producer --tail=5
# Expected: [trace:xxxxxxxx] Published sensorId=...
```

---

## Phase 5a — Kibana Dashboards

See `documentation/observability-setup.md` for the full build runbook.

---

## Phase 5b — Reloader

Reloader (Stakater) watches ConfigMaps and Secrets and triggers rolling restarts
on any Deployment annotated with `reloader.stakater.com/auto: "true"`. This is
what makes the Phase 5b latency injection demo work: ArgoCD syncs the updated
ConfigMap, Reloader detects the change and performs the rollout, and the new pod
picks up the new `BRIDGE_DELAY_MS` value without any manual intervention.

### Step 27 — Install Reloader

```bash
helm repo add stakater https://stakater.github.io/stakater-charts
helm repo update

helm upgrade --install reloader stakater/reloader \
  --namespace kube-system \
  --set reloader.watchGlobally=false
```

> `watchGlobally=false` limits Reloader to only acting on Deployments that carry
> the opt-in annotation — it will not trigger restarts cluster-wide on every
> ConfigMap change. This is the correct setting for a shared cluster.

Wait for the pod to be ready:

```bash
kubectl rollout status deployment/reloader-reloader -n kube-system
kubectl get pods -n kube-system -l app.kubernetes.io/name=reloader
# Expected: 1/1 Running
```

### Step 27b — Verify annotations on app Deployments

The three app Deployments must carry the Reloader opt-in annotation in their
pod template metadata. This is written by `deploy-repo-init.sh`. Verify after
the first ArgoCD sync:

```bash
for APP in sensor-producer mqtt-bridge event-consumer; do
  echo -n "${APP}: "
  kubectl get deployment ${APP} -n sensor-dev \
    -o jsonpath='{.spec.template.metadata.annotations.reloader\.stakater\.com/auto}'
  echo ""
done
# Expected: true (for each app)
```

If any show blank, the annotation is missing from the base manifest. Check
`base/sensor-producer.yaml` (and siblings) in `sensor-demo-deploy` — the
annotation belongs under `spec.template.metadata.annotations`, not at the
Deployment metadata level.

### Step 27c — Smoke test

Trigger a ConfigMap change and confirm Reloader responds:

```bash
# 1. Note current pod names before the change
kubectl get pods -n sensor-dev -l app=mqtt-bridge

# 2. Make a trivial ConfigMap change (or use the BRIDGE_DELAY_MS demo knob
#    via Gitea — see platform-demo-playbook.md). Here we patch directly for
#    a quick smoke test only — in normal operation always go through git:
kubectl patch configmap sensor-config -n sensor-dev \
  --type merge -p '{"data":{"BRIDGE_DELAY_MS":"100"}}'

# 3. Watch Reloader react — should trigger within ~5 seconds
kubectl logs -n kube-system \
  $(kubectl get pod -n kube-system -l app.kubernetes.io/name=reloader \
    -o jsonpath='{.items[0].metadata.name}') \
  --tail=20 | grep -i "mqtt-bridge\|sensor-config"
# Expected: Changes Detected in mqtt-bridge ... Rolling upgrade

# 4. Confirm rollout
kubectl rollout status deployment/mqtt-bridge -n sensor-dev
# Expected: successfully rolled out

# 5. Confirm new pod picked up the value
kubectl logs -n sensor-dev \
  $(kubectl get pod -n sensor-dev -l app=mqtt-bridge \
    -o jsonpath='{.items[0].metadata.name}') \
  -c mqtt-bridge --tail=10 | grep "Bridge delay"
# Expected: Bridge delay: 100ms

# 6. Reset via git (correct operational pattern)
#    Open https://gitea.test/poc/sensor-demo-deploy
#    Set BRIDGE_DELAY_MS back to "0" in envs/dev/kustomization.yaml and commit
```

> **Important:** the direct `kubectl patch` above is for smoke-testing only.
> In the actual demo and in normal operation, all ConfigMap changes go through
> git → ArgoCD. Direct patches are overwritten on the next ArgoCD sync.

---

## Session restart procedure

After any server reboot or cluster restart:

```bash
# Step 1 — check cluster state
docker ps -a | grep k3d

# Step 2 — restart cluster if containers are stopped
k3d cluster start poc
kubectl get nodes -w   # wait for all Ready, Ctrl+C

# Step 3 — start pf-es in a dedicated terminal
pf-es

# Step 4 — run poc-start (unseals Vault, runs vault-init.sh, waits for ES)
poc-start
```

`poc-start` automatically:
1. Waits for Vault pod Ready
2. Starts Vault port-forward in background
3. Unseals Vault
4. Runs vault-init.sh
5. Waits for Elasticsearch
6. Starts the host Gitea Actions runner (`runner-start`)

> **CoreDNS node patch is ephemeral** — the `gitea.test` entry in k3d node
> `/etc/hosts` is lost on cluster restart. Re-run after restart:
> ```bash
> bash ${POC_DIR}/scripts/coredns-patch.sh
> ```
> This is separate from `poc-start` because it requires Traefik to be
> healthy first.

> **After restart:** Elasticsearch takes 2-3 minutes to reach green. OTel
> collector errors during this window are expected and resolve automatically.
> `obs-init` is NOT needed on restarts — only after a full cluster rebuild.

---

## Accessing services

Two access patterns depending on where you are:

**From the Linux host terminal** — use `127.0.0.1` for port-forwarded services,
`.test` URLs work via `/etc/hosts`.

**From your workstation browser** — replace `127.0.0.1` with the server IP or
hostname (`devajk01`). The `.test` URLs resolve via your workstation hosts file.
Port-forwarded services (Vault, ES) are accessible on the server IP because
`kubectl port-forward` binds to all interfaces — note this is insecure and
acceptable for a PoC only.

> Replace `<SERVER_IP>` below with your server's actual IP address or hostname.

| Service | From workstation | From server terminal | Notes |
|---------|-----------------|---------------------|-------|
| Vault UI | http://\<SERVER_IP\>:8200 | http://127.0.0.1:8200 | Requires `pf-vault`. Token: `cat ${POC_DIR}/vault/root-token` |
| Elasticsearch API | https://\<SERVER_IP\>:9200 | https://127.0.0.1:9200 | Requires `pf-es` |
| Kibana | https://kibana.test | https://kibana.test | Login: elastic / `es-pass` |
| Traefik dashboard | https://traefik.test/dashboard/ | https://traefik.test/dashboard/ | |
| Gitea | https://gitea.test | https://gitea.test | Login: poc-admin / `gitea-token` |
| ArgoCD | https://argocd.test | https://argocd.test | Login: admin / `argocd-pass` |
| whoami | https://whoami.test | https://whoami.test | |
| httpbin | https://httpbin.test | https://httpbin.test | |

Passwords are also stored in Vault:

```bash
vault-poc kv get secret/observability/elasticsearch
vault-poc kv get secret/gitea/admin
vault-poc kv get secret/argocd/admin
```

---

## Troubleshooting

### ClusterIssuer vault-issuer stuck False — 403 permission denied

```bash
kubectl describe clusterissuer vault-issuer | grep -A5 "Message:"
```

Fix — vault-init.sh does this automatically, but if needed manually:

```bash
VAULT_TOKEN=$(cat ${POC_DIR}/vault/root-token | tr -d '\r\n')

docker run --rm -i --network host \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  -e VAULT_TOKEN="${VAULT_TOKEN}" \
  devops-toolkit:latest vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc.cluster.local:443" \
    disable_local_ca_jwt=false

kubectl rollout restart deployment/cert-manager -n cert-manager
kubectl get clusterissuer vault-issuer -w
```

### OTel gateway document_parsing_exception on metrics index

Cause: the `metrics-otel` index template is missing named dynamic templates.

```bash
ES_PASS=$(kubectl get secret elasticsearch-es-elastic-user \
  -n observability -o jsonpath='{.data.elastic}' | base64 -d | tr -d '\r\n')

curl -sk -u "elastic:${ES_PASS}" \
  -X DELETE "https://127.0.0.1:9200/_data_stream/metrics-generic.otel-default" \
  | docker run --rm -i devops-toolkit:latest jq .acknowledged

obs-init
kubectl rollout restart deployment/otel-collector-gateway -n observability
```

### Indices yellow — replicas unassigned

Single-node ES cannot allocate replicas. `obs-init` sets these to 0 on
all data streams. If a new stream appears yellow:

```bash
ES_PASS=$(kubectl get secret elasticsearch-es-elastic-user \
  -n observability -o jsonpath='{.data.elastic}' | base64 -d | tr -d '\r\n')

for signal in logs metrics traces; do
  curl -sk -u "elastic:${ES_PASS}" \
    -X PUT "https://127.0.0.1:9200/${signal}-generic.otel-default/_settings" \
    -H "Content-Type: application/json" \
    -d '{"index.number_of_replicas": 0}' | jq .acknowledged
done
```

### Gitea runner Offline or not picking up jobs

```bash
docker logs gitea-runner --tail=30
```

If the container isn't running:

```bash
runner-start
```

If registration failed, re-run `gitea-init.sh` to get a fresh token then restart:

```bash
bash ${POC_DIR}/scripts/gitea-init.sh
runner-stop
docker rm gitea-runner
runner-start
```

To check if the runner config was written correctly:

```bash
cat ${POC_DIR}/tmp/gitea-runner/config.yml
```

### ArgoCD cannot reach Gitea repo

```bash
kubectl logs deployment/argocd-repo-server -n argocd --tail=20 \
  | grep -i "error\|fail"
```

The ArgoCD credential secret must use the internal Gitea URL:

```bash
kubectl get secret gitea-argocd-creds -n argocd \
  -o jsonpath='{.data.url}' | base64 -d
# Expected: http://gitea-http.gitea.svc.cluster.local:3000/poc/sensor-demo-deploy
```

If wrong, re-run `gitea-init.sh` and restart the repo server:

```bash
bash ${POC_DIR}/scripts/gitea-init.sh
kubectl rollout restart deployment/argocd-repo-server -n argocd
```

### Pods stuck in ImagePullBackOff

```bash
kubectl describe pod <pod-name> -n sensor-dev | grep -A5 "Events:"
```

If `no basic auth credentials` — recreate the pull secret:

```bash
GITEA_PASS=$(gitea-token)
for NS in sensor-dev sensor-qa sensor-prod; do
  kubectl create secret docker-registry gitea-registry \
    -n ${NS} \
    --docker-server=gitea.test \
    --docker-username=poc-admin \
    --docker-password="${GITEA_PASS}" \
    --dry-run=client -o yaml \
  | kubectl apply -f -
done
kubectl delete pods -n sensor-dev --all
```

### Messaging credentials out of sync

If apps are failing authentication after a rebuild or crash:

```bash
# Delete both the k8s secret and the Vault KV entry, then regenerate
kubectl delete secret mosquitto-passwd -n messaging

VAULT_TOKEN=$(cat ${POC_DIR}/vault/root-token)
docker run --rm --network host \
  -e VAULT_ADDR=http://127.0.0.1:8200 \
  -e VAULT_TOKEN="${VAULT_TOKEN}" \
  devops-toolkit:latest \
  vault kv metadata delete secret/apps/mqtt

bash ${POC_DIR}/scripts/messaging-init.sh

kubectl delete pod -n messaging -l app=mosquitto
kubectl delete pods -n sensor-dev --all
```

Repeat the same pattern for `redis-password` / `secret/apps/redis` and
`kafka-jaas` / `secret/apps/kafka` if needed.

---

## Versions

| Component | Version |
|-----------|---------|
| k3d | 5.7.5 |
| k3s | v1.30.6+k3s1 |
| Vault (server) | 1.21.2 |
| cert-manager | v1.20.0 |
| Traefik (Helm/app) | 39.0.5 / v3.6.10 |
| ECK operator | latest |
| Elasticsearch | 8.17.0 |
| Kibana | 8.17.0 |
| OTel Collector Contrib | 0.123.0 |
| Gitea (Helm/app) | 12.5.0 / 1.25.4 |
| ArgoCD (Helm/app) | 9.4.15 / v3.3.4 |
| Eclipse Mosquitto | 2.0 |
| Redis | 7-alpine |
| Apache Kafka | 3.8.0 |
| .NET | 6.0 |
| kubectl | 1.34.1 |
| helm | 3.19.0 |
