#!/bin/bash
#
# poc-capture.sh — packet capture orchestrator for the PoC
#
# Why this script bypasses the kubectl alias:
#   The PoC's kubectl alias is `docker run --rm -it ...` — the -t (TTY) mangles
#   binary streams, so `kubectl exec ... tar cf -` over a pipe produces corrupt
#   data. We call docker directly with -i only (no TTY) so the tar stream is
#   preserved. Same toolkit image, same kubeconfig, just clean stdin/stdout.
#
# Usage:
#   ./poc-capture.sh start [duration_seconds]   # default 60
#   ./poc-capture.sh stop
#   ./poc-capture.sh extract [timestamp]
#   ./poc-capture.sh clean                      # wipe pod-side /captures
#   ./poc-capture.sh status

set -euo pipefail

# Configuration
NAMESPACE="messaging"
LABEL="name=poc-packet-capture"
NODES=(k3d-poc-server-0 k3d-poc-agent-0 k3d-poc-agent-1)
INTERFACE="flannel.1"
BPF_FILTER="port 1883 or port 9092 or port 6379"

# Use POC_DIR from environment, else default
POC_DIR="${POC_DIR:-${HOME}/Projects/poc}"
TOOLKIT_IMAGE="${TOOLKIT_IMAGE:-devops-toolkit:latest}"
LOCAL_BASE="${POC_DIR}/captures"
STATE_FILE="/tmp/poc-capture.state"

# Color helpers
BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()   { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}!${NC} $1"; }
err()   { echo -e "${RED}✗${NC} $1"; }

# kubectl wrapper — no TTY, safe for binary pipes and scripted use
# Single function for all calls; we don't need TTY anywhere in this script.
kctl() {
  docker run --rm -i --network host \
    -v "${POC_DIR}/kube:/root/.kube" \
    -e KUBECONFIG=/root/.kube/config \
    "${TOOLKIT_IMAGE}" kubectl "$@"
}

# Pre-flight checks
preflight() {
  if ! command -v docker >/dev/null 2>&1; then
    err "docker not found in PATH"
    exit 1
  fi
  if ! docker image inspect "${TOOLKIT_IMAGE}" >/dev/null 2>&1; then
    err "toolkit image not found: ${TOOLKIT_IMAGE}"
    exit 1
  fi
  if [[ ! -f "${POC_DIR}/kube/config" ]]; then
    err "kubeconfig not found at ${POC_DIR}/kube/config"
    exit 1
  fi
}

pod_for_node() {
  kctl get pod -l "$LABEL" -n "$NAMESPACE" \
    --field-selector "spec.nodeName=$1" \
    -o jsonpath='{.items[0].metadata.name}'
}

cmd_start() {
  preflight
  local duration="${1:-60}"
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  echo "$timestamp" > "$STATE_FILE"

  log "Starting capture — timestamp: $timestamp, duration: ${duration}s"
  log "Filter: $BPF_FILTER on interface $INTERFACE"

  for node in "${NODES[@]}"; do
    local pod
    pod=$(pod_for_node "$node")
    if [[ -z "$pod" ]]; then
      err "no capture pod on $node — aborting"
      exit 1
    fi
    log "  $node ($pod)"
    kctl exec -n "$NAMESPACE" "$pod" -- sh -c \
      "nohup tcpdump -i $INTERFACE -nn -w /captures/${node}-${timestamp}.pcap \
       '$BPF_FILTER' >/captures/${node}.log 2>&1 & echo \$! > /captures/${node}.pid"
  done

  ok "Captures running. Sleeping ${duration}s..."
  sleep "$duration"

  cmd_stop
}

cmd_stop() {
  preflight
  if [[ ! -f "$STATE_FILE" ]]; then
    err "No state file at $STATE_FILE — nothing to stop"
    exit 1
  fi
  local timestamp
  timestamp=$(cat "$STATE_FILE")
  log "Stopping captures (timestamp: $timestamp)"

  for node in "${NODES[@]}"; do
    local pod
    pod=$(pod_for_node "$node")
    kctl exec -n "$NAMESPACE" "$pod" -- sh -c \
      "kill \$(cat /captures/${node}.pid) 2>/dev/null; sleep 1; \
       ls -lh /captures/${node}-${timestamp}.pcap 2>/dev/null || echo 'NO PCAP'"
  done

  ok "Captures stopped. Run: $0 extract"
}

cmd_extract() {
  preflight
  local timestamp="${1:-$(cat "$STATE_FILE" 2>/dev/null || echo '')}"
  if [[ -z "$timestamp" ]]; then
    err "No timestamp provided and no state file."
    err "Usage: $0 extract <timestamp>"
    exit 1
  fi

  local outdir="${LOCAL_BASE}/${timestamp}"
  mkdir -p "$outdir"
  log "Extracting pcaps to $outdir"

  for node in "${NODES[@]}"; do
    local pod
    pod=$(pod_for_node "$node")
    local remote_file="${node}-${timestamp}.pcap"
    log "  $node — tar streaming ${remote_file}"
    # tar over stdout — kctl uses -i only (no TTY), so binary stream is intact
    if kctl exec -n "$NAMESPACE" "$pod" -- tar cf - -C /captures "$remote_file" \
        | tar xf - -C "$outdir" 2>/dev/null; then
      if [[ -f "$outdir/$remote_file" ]]; then
        mv "$outdir/$remote_file" "$outdir/${node}.pcap"
        ok "    extracted $(du -h "$outdir/${node}.pcap" | cut -f1)"
      else
        err "    tar extraction produced no file"
      fi
    else
      err "    tar pipe failed for $node"
    fi
  done

  log "Files in $outdir:"
  ls -lh "$outdir"
}

cmd_clean() {
  preflight
  log "Cleaning /captures on all capture pods"
  for node in "${NODES[@]}"; do
    local pod
    pod=$(pod_for_node "$node")
    echo "=== $node ==="
    kctl exec -n "$NAMESPACE" "$pod" -- sh -c \
      'ls /captures/ 2>/dev/null; rm -rf /captures/* /captures/.[!.]* 2>/dev/null; echo "  cleaned"'
  done
  rm -f "$STATE_FILE"
  ok "Cleaned"
}

cmd_status() {
  preflight
  log "Capture pod status:"
  kctl get pods -l "$LABEL" -n "$NAMESPACE" -o wide

  echo ""
  log "Files on each pod:"
  for node in "${NODES[@]}"; do
    local pod
    pod=$(pod_for_node "$node")
    echo "=== $node ($pod) ==="
    kctl exec -n "$NAMESPACE" "$pod" -- ls -lh /captures/ 2>/dev/null || echo "  (error)"
  done

  if [[ -f "$STATE_FILE" ]]; then
    echo ""
    log "Last capture timestamp: $(cat "$STATE_FILE")"
  fi
}

case "${1:-help}" in
  start)   cmd_start "${2:-60}" ;;
  stop)    cmd_stop ;;
  extract) cmd_extract "${2:-}" ;;
  clean)   cmd_clean ;;
  status)  cmd_status ;;
  *)
    cat <<EOF
poc-capture.sh — packet capture orchestrator for the PoC

Bypasses the ZSH kubectl alias to avoid TTY-related binary stream corruption
during pcap extraction. Calls the same toolkit container directly with -i only.

Commands:
  start [duration]       Start capture, sleep duration seconds, then stop (default 60s)
  stop                   Stop running captures (uses last start's timestamp)
  extract [timestamp]    Pull pcaps from pods to ${LOCAL_BASE}/<timestamp>/
                         (uses state file if no timestamp given)
  clean                  Wipe /captures on all pods + remove state file
  status                 Show pod status and pod-side file listing

Workflow:
  $0 start 60
  $0 extract             # uses timestamp from start
  # ... analyze pcaps in ${LOCAL_BASE}/<timestamp>/
  $0 clean               # wipe pods when done

Configuration (env overrides):
  POC_DIR        ${POC_DIR}
  TOOLKIT_IMAGE  ${TOOLKIT_IMAGE}
EOF
    ;;
esac
