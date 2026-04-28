#!/usr/bin/env bash
# scripts/capture-logging-evidence.sh
# Capture a reproducible snapshot of the current logging state for the
# three-service sensor pipeline. Output is written under
# ${POC_DIR}/documentation/evidence/<mode>/ and is designed to be
# committed to the repo and/or pulled back to a workstation via
# poc-sync-pull for analysis.
#
# Captures:
#   - Raw Loki log records (JSON) per service over a query window
#   - Deployed chart versions from Helm
#   - Deployed container images from the actual workloads
#   - .NET SDK and OpenTelemetry package versions from the app source
#   - The LogQL queries used (for reproducibility)
#   - A README.md documenting when/what/why/how
#
# Does NOT capture:
#   - Grafana screenshots — those must be added to the same directory
#     by hand; the script mentions this in its final summary.
#
# Prerequisites:
#   - pf-loki running (port-forward svc/loki -n observability 3100:3100)
#   - docker, curl, jq on the host
#   - devops-toolkit image pulled (kubectl + helm run through it)
#   - Kubeconfig at ${POC_DIR}/kube/config (standard PoC layout)
#
# Usage:
#   bash scripts/capture-logging-evidence.sh                     # writes to evidence/before/
#   bash scripts/capture-logging-evidence.sh --mode after        # writes to evidence/after/
#   bash scripts/capture-logging-evidence.sh --minutes 5         # custom query window (default: 2)
#   bash scripts/capture-logging-evidence.sh --mode after --minutes 5

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[capture-evidence]${NC} $*"; }
warn() { echo -e "${YELLOW}[capture-evidence]${NC} $*"; }
err()  { echo -e "${RED}[capture-evidence] ERROR:${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BLUE}── $* ──${NC}"; }

# ── Toolkit image wrappers ────────────────────────────────────────────────
# kubectl and helm run through the devops-toolkit container in this PoC.
# The toolkit aliases defined in poc-toolkit.zsh are zsh aliases and do not
# resolve inside bash scripts, so we replicate their invocation shape here
# as bash functions. This keeps the script self-contained: it runs under
# `bash scripts/capture-logging-evidence.sh` with no shell-specific setup.
TOOLKIT_IMAGE="${TOOLKIT_IMAGE:-devops-toolkit:latest}"

kubectl() {
  docker run --rm --network host \
    -v "${POC_DIR}/kube:/root/.kube" \
    -e KUBECONFIG=/root/.kube/config \
    "${TOOLKIT_IMAGE}" kubectl "$@"
}

helm() {
  docker run --rm --network host \
    -v "${POC_DIR}/kube:/root/.kube" \
    -v "${POC_DIR}/helm-cache:/root/.cache/helm" \
    -v "${POC_DIR}/helm-config:/root/.config/helm" \
    -e KUBECONFIG=/root/.kube/config \
    -e HELM_CACHE_HOME=/root/.cache/helm \
    -e HELM_CONFIG_HOME=/root/.config/helm \
    "${TOOLKIT_IMAGE}" helm "$@"
}

# ── Defaults and arg parsing ──────────────────────────────────────────────
MODE="before"
MINUTES="2"
LOKI_URL="http://127.0.0.1:3100"
SERVICES=("sensor-producer" "mqtt-bridge" "event-consumer")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      if [[ "${MODE}" != "before" && "${MODE}" != "after" ]]; then
        err "--mode must be 'before' or 'after', got: ${MODE}"
      fi
      shift 2
      ;;
    --minutes)
      MINUTES="${2:-}"
      if ! [[ "${MINUTES}" =~ ^[0-9]+$ ]]; then
        err "--minutes must be a positive integer, got: ${MINUTES}"
      fi
      shift 2
      ;;
    -h|--help)
      sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      err "Unknown argument: $1 (try --help)"
      ;;
  esac
done

OUT_DIR="${POC_DIR}/documentation/evidence/${MODE}"

# ── Preflight checks ──────────────────────────────────────────────────────
step "Preflight checks"

command -v curl   >/dev/null || err "curl not found on PATH"
command -v jq     >/dev/null || err "jq not found on PATH"
command -v docker >/dev/null || err "docker not found on PATH (toolkit image runs via docker)"

# Verify the toolkit image is available locally.
if ! docker image inspect "${TOOLKIT_IMAGE}" >/dev/null 2>&1; then
  err "toolkit image ${TOOLKIT_IMAGE} not found locally — run: docker pull ${TOOLKIT_IMAGE}"
fi
log "Toolkit image present: ${TOOLKIT_IMAGE}"

# Verify pf-loki is reachable. If this fails everything else fails silently.
if ! curl -sSf --max-time 3 "${LOKI_URL}/ready" >/dev/null 2>&1; then
  err "Loki not reachable at ${LOKI_URL}/ready — is pf-loki running in another terminal?"
fi
log "Loki reachable at ${LOKI_URL}"

# Verify kubectl through the toolkit can reach the cluster.
if ! kubectl get ns observability >/dev/null 2>&1; then
  err "kubectl (via toolkit) cannot reach the cluster (namespace 'observability' not found)"
fi
log "Cluster reachable"

# ── Prepare output directory ──────────────────────────────────────────────
step "Preparing output directory: ${OUT_DIR}"

# Clean slate — wipe anything from a prior run of the same mode.
# Git history is the archive; the working copy is always the latest capture.
if [[ -d "${OUT_DIR}" ]]; then
  warn "Existing ${MODE}/ directory found — removing for clean capture"
  rm -rf "${OUT_DIR}"
fi
mkdir -p "${OUT_DIR}"
log "Output directory ready"

# ── Compute the query time window ─────────────────────────────────────────
# Loki expects nanosecond epoch timestamps. POSIX date gives us seconds;
# we pad with 9 zeros. GNU date is assumed (Debian host).
NOW_S=$(date +%s)
START_S=$((NOW_S - MINUTES * 60))
END_NS="${NOW_S}000000000"
START_NS="${START_S}000000000"
ISO_NOW=$(date -u -d "@${NOW_S}" +%Y-%m-%dT%H:%M:%SZ)
ISO_START=$(date -u -d "@${START_S}" +%Y-%m-%dT%H:%M:%SZ)

log "Query window: ${ISO_START} → ${ISO_NOW}  (${MINUTES} minutes)"

# ── Capture per-service log records ───────────────────────────────────────
step "Capturing Loki log records"

for svc in "${SERVICES[@]}"; do
  log "Querying ${svc}..."
  outfile="${OUT_DIR}/${svc}-raw.json"

  # Per-stream line limit — Loki caps at 5000 per stream by default.
  # 2 min × 60 s × ~1 rec/s = ~120 per service; 500 is comfortable headroom
  # and supports --minutes overrides up to ~8 min without hitting the cap.
  if curl -sSG "${LOKI_URL}/loki/api/v1/query_range" \
       --data-urlencode "query={service_name=\"${svc}\"}" \
       --data-urlencode "start=${START_NS}" \
       --data-urlencode "end=${END_NS}" \
       --data-urlencode "limit=500" \
       --data-urlencode "direction=forward" \
       -o "${outfile}"; then

    # Validate the response parsed as JSON and has a success status.
    if ! jq -e '.status == "success"' "${outfile}" >/dev/null 2>&1; then
      warn "  Response for ${svc} did not report status=success — inspect ${outfile}"
    else
      count=$(jq '[.data.result[].values[]] | length' "${outfile}")
      log "  ${svc}: ${count} records captured"
    fi
  else
    warn "  curl failed for ${svc} — check pf-loki and rerun"
  fi
done

# ── Capture the exact LogQL queries used ──────────────────────────────────
step "Recording queries used"

cat > "${OUT_DIR}/queries.md" <<EOF
# LogQL queries used for this capture

**Captured:** ${ISO_NOW}
**Window:** ${ISO_START} → ${ISO_NOW} (${MINUTES} minutes)
**Loki endpoint:** ${LOKI_URL}

## Per-service raw record queries

One query per service, one file per service:

\`\`\`logql
{service_name="sensor-producer"}
{service_name="mqtt-bridge"}
{service_name="event-consumer"}
\`\`\`

## API call shape

\`\`\`
GET ${LOKI_URL}/loki/api/v1/query_range
  ?query={service_name="<svc>"}
  &start=${START_NS}
  &end=${END_NS}
  &limit=2000
  &direction=forward
\`\`\`

## Equivalent Grafana Explore queries

To reproduce the same record set in Grafana Explore (which the screenshots
in this directory were taken from):

\`\`\`logql
{service_name=~"sensor-producer|mqtt-bridge|event-consumer"}
\`\`\`

Set the time range to the window above.
EOF
log "queries.md written"

# ── Capture deployed versions from the live cluster ───────────────────────
step "Recording deployed versions"

versions_file="${OUT_DIR}/versions.md"
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")

{
  echo "# Deployed versions at time of capture"
  echo
  echo "**Captured:** ${ISO_NOW}"
  echo "**Cluster:** ${CURRENT_CONTEXT}"
  echo
  echo "## Helm releases (chart versions)"
  echo
  echo '```'
} > "${versions_file}"

# helm list -A returns JSON; we pick the fields that matter for reproducibility.
helm list -A -o json 2>/dev/null \
  | jq -r '.[] | [.namespace, .name, .chart, .app_version] | @tsv' \
  | awk 'BEGIN {printf "%-16s %-28s %-40s %s\n", "NAMESPACE", "RELEASE", "CHART", "APP_VERSION"; print "--------------------------------------------------------------------------------------------------"}
         {printf "%-16s %-28s %-40s %s\n", $1, $2, $3, $4}' \
  >> "${versions_file}"

{
  echo '```'
  echo
  echo "## Sensor pipeline container images (running pods)"
  echo
  echo '```'
} >> "${versions_file}"

# Pull the actual image tag running in each deployment. The helm app_version
# above is the chart-declared version; this is what's actually on-cluster.
for svc in "${SERVICES[@]}"; do
  # Services live in sensor-dev per the PoC convention. Adjust if the
  # target environment changes.
  img=$(kubectl get deploy "${svc}" -n sensor-dev \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "not-found")
  printf "%-20s %s\n" "${svc}" "${img}" >> "${versions_file}"
done

{
  echo '```'
  echo
  echo "## OTel collector image"
  echo
  echo '```'
} >> "${versions_file}"

kubectl get deploy otel-collector-gateway -n observability \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
  >> "${versions_file}" || echo "not-found" >> "${versions_file}"
echo >> "${versions_file}"

{
  echo '```'
  echo
  echo "## .NET SDK and OpenTelemetry package versions (from app source)"
  echo
  echo '```'
} >> "${versions_file}"

# Read package versions directly from the app .csproj files.
# These are source-of-truth for what's in the container image.
for svc in "${SERVICES[@]}"; do
  csproj="${POC_DIR}/apps/${svc}/${svc}.csproj"
  if [[ -f "${csproj}" ]]; then
    echo "--- ${svc} ---" >> "${versions_file}"
    # TargetFramework first, then any OpenTelemetry.* package refs.
    grep -E '<TargetFramework>|OpenTelemetry\.' "${csproj}" \
      | sed 's/^[[:space:]]*//' >> "${versions_file}" || true
    echo >> "${versions_file}"
  else
    echo "--- ${svc} --- (csproj not found at ${csproj})" >> "${versions_file}"
  fi
done

{
  echo '```'
  echo
  echo "## Git commit at time of capture"
  echo
  echo '```'
} >> "${versions_file}"

# Capture the git SHA if this is a git checkout. Useful for cross-referencing
# the code state with the log output.
if git -C "${POC_DIR}" rev-parse HEAD >/dev/null 2>&1; then
  git -C "${POC_DIR}" log -1 --format='%H  %s  (%ci)' >> "${versions_file}"
else
  echo "not a git checkout (${POC_DIR})" >> "${versions_file}"
fi

echo '```' >> "${versions_file}"
log "versions.md written"

# ── Write the README explaining this directory ────────────────────────────
step "Writing README.md"

cat > "${OUT_DIR}/README.md" <<EOF
# Logging evidence — ${MODE}

This directory is a point-in-time capture of the logging pipeline state.
It exists to support before/after comparison when changes are made to
app logging, the OTel collector, or Loki.

## What's in here

| File | Purpose |
|------|---------|
| \`sensor-producer-raw.json\` | Raw Loki API response for the sensor-producer stream |
| \`mqtt-bridge-raw.json\`     | Raw Loki API response for the mqtt-bridge stream |
| \`event-consumer-raw.json\`  | Raw Loki API response for the event-consumer stream |
| \`queries.md\`               | Exact LogQL queries and API calls used |
| \`versions.md\`              | Helm chart versions, container images, OTel package versions, git SHA |
| \`README.md\`                | This file |

Screenshots (PNG) from the Grafana Explore view at the same time window
should be added to this directory by hand — the script cannot capture them.

## When this was captured

**Timestamp:** ${ISO_NOW}
**Query window:** ${ISO_START} → ${ISO_NOW} (${MINUTES} minutes)
**Mode:** ${MODE}

## How to reproduce

\`\`\`bash
# In one terminal — port-forward Loki
pf-loki

# In another terminal — run the capture script
bash scripts/capture-logging-evidence.sh --mode ${MODE} --minutes ${MINUTES}
\`\`\`

## How to diff before vs after

Once both \`before/\` and \`after/\` directories exist:

\`\`\`bash
# Coarse: which fields changed, which went away, which appeared
diff <(jq -S '[.data.result[].values[][1] | fromjson? // .] | .[0]' documentation/evidence/before/sensor-producer-raw.json) \\
     <(jq -S '[.data.result[].values[][1] | fromjson? // .] | .[0]' documentation/evidence/after/sensor-producer-raw.json)

# Line-level: body text changes
diff <(jq -r '.data.result[].values[][1]' documentation/evidence/before/sensor-producer-raw.json | head -20) \\
     <(jq -r '.data.result[].values[][1]' documentation/evidence/after/sensor-producer-raw.json | head -20)
\`\`\`

## Provenance note

Raw JSON files are the authoritative evidence. Screenshots are illustrative.
If the two disagree, trust the JSON — it's what the system actually emitted.
EOF
log "README.md written"

# ── Summary ───────────────────────────────────────────────────────────────
step "Capture complete"

log "Output: ${OUT_DIR}"
echo
ls -la "${OUT_DIR}"
echo
log "Next steps:"
echo "  1. Add screenshots (PNG) from Grafana Explore to ${OUT_DIR}/"
echo "     Suggested names: screenshot-explore-view.png, screenshot-field-inspector.png"
echo "  2. Review README.md and versions.md for accuracy"
echo "  3. Commit the whole directory to git"
echo "  4. If pulling to workstation, use: poc-sync-pull"
