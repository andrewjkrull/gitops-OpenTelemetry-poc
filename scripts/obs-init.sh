#!/usr/bin/env bash
# obs-init.sh — initializes Elasticsearch for the OTel pipeline
# Run after a cluster rebuild or PVC wipe — not needed for simple restarts
# (index templates survive pod restarts, only lost if PVC is deleted)
#
# Usage: bash ~/Projects/poc/obs-init.sh
# Requires:
#   - pf-vault running in a dedicated terminal (for credential retrieval)
#   - pf-es running in a dedicated terminal (for ES API access)
#   - Elasticsearch pod healthy (kubectl get elasticsearch -n observability)

set -euo pipefail

VAULT_ADDR="http://127.0.0.1:8200"
VAULT_TOKEN=$(cat "${HOME}/Projects/poc/vault/root-token" 2>/dev/null | tr -d '%\n') \
  || die "Cannot read root token from ~/Projects/poc/vault/root-token"
ES_ADDR="https://127.0.0.1:9200"
TOOLKIT_IMAGE="devops-toolkit:latest"
TMP_DIR="${POC_DIR:-${HOME}/Projects/poc}/tmp"
KUBE_DIR="$HOME/Projects/poc/kube"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)]${NC} $1"; }
die()  { echo -e "${RED}[$(date +%H:%M:%S)] ERROR:${NC} $1"; exit 1; }

vault_cmd() {
  docker run --rm --network host \
    -v "${TMP_DIR}:/tmp/poc" \
    -e VAULT_ADDR="${VAULT_ADDR}" \
    -e VAULT_TOKEN="${VAULT_TOKEN}" \
    "${TOOLKIT_IMAGE}" vault "$@"
}

kubectl_cmd() {
  docker run --rm --network host \
    -v "${KUBE_DIR}:/root/.kube" \
    -e KUBECONFIG=/root/.kube/config \
    "${TOOLKIT_IMAGE}" kubectl "$@"
}

es_cmd() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  if [[ -n "${body}" ]]; then
    curl -sk -u "elastic:${ES_PASS}" \
      -X "${method}" "${ES_ADDR}${path}" \
      -H "Content-Type: application/json" \
      -d "${body}"
  else
    curl -sk -u "elastic:${ES_PASS}" \
      -X "${method}" "${ES_ADDR}${path}"
  fi
}

# ============================================================
# Preflight checks
# ============================================================
log "Checking Vault connectivity..."
vault_cmd status > /dev/null 2>&1 \
  || die "Cannot reach Vault at ${VAULT_ADDR}. Is pf-vault running?"
log "Vault is reachable"

log "Retrieving Elasticsearch password from Vault..."
# Use -format=json to avoid ANSI escape codes in Vault CLI output
ES_PASS=$(vault_cmd kv get -format=json \
  secret/observability/elasticsearch 2>/dev/null \
  | docker run --rm -i "${TOOLKIT_IMAGE}" jq -r '.data.data.password') \
  || die "Could not retrieve ES password from Vault. Has vault-init.sh been run with Phase 2 deployed?"
log "Credentials retrieved"

log "Checking Elasticsearch connectivity..."
ES_STATUS=$(es_cmd GET "/_cluster/health" \
  | docker run --rm -i "${TOOLKIT_IMAGE}" jq -r '.status' 2>/dev/null) \
  || die "Cannot reach Elasticsearch at ${ES_ADDR}. Is pf-es running?"
[[ "${ES_STATUS}" == "green" || "${ES_STATUS}" == "yellow" ]] \
  || die "Elasticsearch health is '${ES_STATUS}' — wait for green/yellow before continuing"
log "Elasticsearch is reachable (status: ${ES_STATUS})"

# ============================================================
# OTel index templates
# metrics-otel uses named dynamic templates (counter_double, gauge_double, etc.)
# required by the ES exporter ECS mode. logs and traces use all_strings_as_keyword.
# ============================================================
log "Creating OTel index templates..."

# metrics template — must include named dynamic templates for ES exporter ECS mode
METRICS_TEMPLATE='{
  "index_patterns": ["metrics-*"],
  "data_stream": {},
  "priority": 150,
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0
    },
    "mappings": {
      "dynamic": true,
      "dynamic_templates": [
        { "counter_double":  { "mapping": { "type": "double" } } },
        { "gauge_double":    { "mapping": { "type": "double" } } },
        { "counter_long":    { "mapping": { "type": "long" } } },
        { "gauge_long":      { "mapping": { "type": "long" } } },
        { "summary_double":  { "mapping": { "type": "double" } } },
        { "all_strings_as_keyword": {
            "match_mapping_type": "string",
            "mapping": { "type": "keyword", "ignore_above": 1024 }
          }
        }
      ],
      "properties": {
        "@timestamp": { "type": "date" }
      }
    }
  }
}'

RESULT=$(es_cmd PUT "/_index_template/metrics-otel" "${METRICS_TEMPLATE}" \
  | docker run --rm -i "${TOOLKIT_IMAGE}" jq -r '.acknowledged')
if [[ "${RESULT}" == "true" ]]; then
  log "  metrics-otel template: OK"
else
  warn "  metrics-otel template: unexpected response — check ES logs"
fi

# logs and traces templates — all_strings_as_keyword only
for signal in logs traces; do
  RESULT=$(es_cmd PUT "/_index_template/${signal}-otel" "{
    \"index_patterns\": [\"${signal}-*\"],
    \"data_stream\": {},
    \"priority\": 150,
    \"template\": {
      \"settings\": {
        \"number_of_shards\": 1,
        \"number_of_replicas\": 0
      },
      \"mappings\": {
        \"dynamic\": true,
        \"dynamic_templates\": [
          {
            \"all_strings_as_keyword\": {
              \"match_mapping_type\": \"string\",
              \"mapping\": { \"type\": \"keyword\", \"ignore_above\": 1024 }
            }
          }
        ],
        \"properties\": {
          \"@timestamp\": { \"type\": \"date\" }
        }
      }
    }
  }" | docker run --rm -i "${TOOLKIT_IMAGE}" jq -r '.acknowledged')

  if [[ "${RESULT}" == "true" ]]; then
    log "  ${signal}-otel template: OK"
  else
    warn "  ${signal}-otel template: unexpected response — check ES logs"
  fi
done

# ============================================================
# Verify templates
# ============================================================
log "Verifying templates..."
TEMPLATE_COUNT=0
for signal in logs metrics traces; do
  EXISTS=$(es_cmd GET "/_index_template/${signal}-otel" \
    | docker run --rm -i "${TOOLKIT_IMAGE}" \
      jq -r '.index_templates | length' 2>/dev/null)
  if [[ "${EXISTS}" == "1" ]]; then
    TEMPLATE_COUNT=$((TEMPLATE_COUNT + 1))
  else
    warn "  ${signal}-otel template not found after creation"
  fi
done

if [[ "${TEMPLATE_COUNT}" == "3" ]]; then
  log "All 3 templates verified"
else
  warn "Only ${TEMPLATE_COUNT}/3 templates verified — re-run if collectors fail to write"
fi

# ============================================================
# Fix replica count on any existing data streams
# ============================================================
log "Checking for existing data streams with replicas > 0..."

for signal in logs metrics traces; do
  INDEX="${signal}-generic.otel-default"
  STATUS=$(es_cmd GET "/_cat/indices/${INDEX}?h=health" 2>/dev/null | tr -d '[:space:]')
  if [[ "${STATUS}" == "yellow" ]]; then
    warn "  ${INDEX} is yellow — setting replicas to 0"
    es_cmd PUT "/${INDEX}/_settings" \
      '{"index.number_of_replicas": 0}' \
      | docker run --rm -i "${TOOLKIT_IMAGE}" jq -r '.acknowledged' > /dev/null
    log "  ${INDEX}: replicas set to 0"
  elif [[ "${STATUS}" == "green" ]]; then
    log "  ${INDEX}: green"
  else
    log "  ${INDEX}: not yet created (will be created on first write)"
  fi
done

# ============================================================
# Recreate otel-es-credentials secret
# Write password via file to avoid shell escaping of special characters
# ============================================================
log "Syncing otel-es-credentials secret..."
if kubectl_cmd get secret otel-es-credentials -n observability > /dev/null 2>&1; then
  kubectl_cmd delete secret otel-es-credentials -n observability
fi

echo -n "${ES_PASS}" > "${TMP_DIR}/es-pass.txt"

docker run --rm --network host \
  -v "${KUBE_DIR}:/root/.kube" \
  -v "${TMP_DIR}:/tmp/poc" \
  -e KUBECONFIG=/root/.kube/config \
  "${TOOLKIT_IMAGE}" kubectl create secret generic otel-es-credentials \
  -n observability \
  --from-file=password=/tmp/poc/es-pass.txt

rm -f "${TMP_DIR}/es-pass.txt"
log "otel-es-credentials secret recreated"

# ============================================================
# Restart OTel collectors if deployed
# ============================================================
GATEWAY_EXISTS=$(kubectl_cmd get deployment otel-collector-gateway \
  -n observability 2>/dev/null && echo "yes" || echo "no")
DAEMONSET_EXISTS=$(kubectl_cmd get daemonset otel-collector-daemonset \
  -n observability 2>/dev/null && echo "yes" || echo "no")

if [[ "${GATEWAY_EXISTS}" == "yes" || "${DAEMONSET_EXISTS}" == "yes" ]]; then
  log "Restarting OTel collectors..."
  if [[ "${GATEWAY_EXISTS}" == "yes" ]]; then
    kubectl_cmd rollout restart deployment/otel-collector-gateway -n observability
    kubectl_cmd rollout status deployment/otel-collector-gateway \
      -n observability --timeout=60s
  fi
  if [[ "${DAEMONSET_EXISTS}" == "yes" ]]; then
    kubectl_cmd rollout restart daemonset/otel-collector-daemonset -n observability
  fi
  log "OTel collectors restarted"
else
  warn "OTel collectors not yet deployed — skipping restart"
  warn "  Apply otel-gateway.yaml and otel-daemonset.yaml, then re-run this script"
fi

# ============================================================
# Summary
# ============================================================
echo ""
log "Observability init complete."
echo ""
log "Index templates:    logs-otel, metrics-otel, traces-otel"
log "Credentials secret: otel-es-credentials (observability namespace)"
log "Kibana:             https://kibana.test"
log "  username:         elastic"
log "  password:         vault-poc kv get -format=json secret/observability/elasticsearch | jq -r '.data.data.password'"
echo ""
log "Wait ~30s after collectors are deployed, then verify data streams:"
log "  ES_PASS=\$(vault-poc kv get -format=json secret/observability/elasticsearch | jq -r '.data.data.password')"
log "  curl -sk -u \"elastic:\${ES_PASS}\" \\"
log "    \"https://127.0.0.1:9200/_cat/indices?v&s=index&h=index,health,docs.count\" \\"
log "    | grep generic.otel"
