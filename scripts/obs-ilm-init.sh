#!/usr/bin/env bash
# obs-ilm-init.sh — applies 2-hour ILM delete policy to all three OTel data streams
# Run after obs-init.sh on a fresh cluster, or any time after a PVC wipe.
# Safe to re-run — all operations are idempotent.
#
# Retention is intentionally short (2h) — this is a live demo platform, not a
# logging archive. Short retention keeps ES index sizes small and queries fast.
#
# Usage: bash ~/Projects/poc/scripts/obs-ilm-init.sh
# Requires:
#   - pf-vault running in a dedicated terminal (for credential retrieval)
#   - pf-es running in a dedicated terminal (for ES API access)
#   - Elasticsearch pod healthy (kubectl get elasticsearch -n observability)
#   - obs-init.sh already run (index templates must exist)

set -euo pipefail

VAULT_ADDR="http://127.0.0.1:8200"
VAULT_TOKEN="$(cat "${HOME}/Projects/poc/vault/root-token" 2>/dev/null | tr -d '\r\n')"
ES_ADDR="https://127.0.0.1:9200"
TOOLKIT_IMAGE="devops-toolkit:latest"
TMP_DIR="${POC_DIR:-${HOME}/Projects/poc}/tmp"

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
ES_PASS=$(vault_cmd kv get -format=json \
  secret/observability/elasticsearch 2>/dev/null \
  | docker run --rm -i "${TOOLKIT_IMAGE}" jq -r '.data.data.password') \
  || die "Could not retrieve ES password from Vault. Has vault-init.sh been run?"
log "Credentials retrieved"

log "Checking Elasticsearch connectivity..."
ES_STATUS=$(es_cmd GET "/_cluster/health" \
  | docker run --rm -i "${TOOLKIT_IMAGE}" jq -r '.status' 2>/dev/null) \
  || die "Cannot reach Elasticsearch at ${ES_ADDR}. Is pf-es running?"
[[ "${ES_STATUS}" == "green" || "${ES_STATUS}" == "yellow" ]] \
  || die "Elasticsearch health is '${ES_STATUS}' — wait for green/yellow before continuing"
log "Elasticsearch is reachable (status: ${ES_STATUS})"

# ============================================================
# Verify obs-init.sh has been run (templates must exist)
# ============================================================
log "Verifying index templates exist..."
TEMPLATE_COUNT=0
for signal in logs metrics traces; do
  EXISTS=$(es_cmd GET "/_index_template/${signal}-otel" \
    | docker run --rm -i "${TOOLKIT_IMAGE}" \
      jq -r '.index_templates | length' 2>/dev/null)
  [[ "${EXISTS}" == "1" ]] && TEMPLATE_COUNT=$((TEMPLATE_COUNT + 1))
done
[[ "${TEMPLATE_COUNT}" == "3" ]] \
  || die "Only ${TEMPLATE_COUNT}/3 index templates found. Run obs-init.sh first."
log "All 3 index templates confirmed"

# ============================================================
# Create ILM policy: poc-2h-delete
# Single delete phase — no warm/cold tiers needed for a PoC.
# Rolls at 2h or 500mb, then deletes immediately.
# min_age on delete is measured from rollover, not ingest time.
# ============================================================
log "Creating ILM policy: poc-2h-delete (2h retention)..."
ILM_RESULT=$(es_cmd PUT "/_ilm/policy/poc-2h-delete" '{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": {
          "rollover": {
            "max_age": "2h",
            "max_primary_shard_size": "500mb"
          }
        }
      },
      "delete": {
        "min_age": "0ms",
        "actions": {
          "delete": {}
        }
      }
    }
  }
}' | docker run --rm -i "${TOOLKIT_IMAGE}" jq -r '.acknowledged')

if [[ "${ILM_RESULT}" == "true" ]]; then
  log "  poc-2h-delete policy: OK"
else
  die "Failed to create ILM policy — response was not acknowledged"
fi

# ============================================================
# Update each index template to reference the ILM policy
# Patches the existing templates created by obs-init.sh
# metrics-otel must retain named dynamic templates (counter_double, gauge_double)
# required by ES exporter ECS mode — these are preserved here.
# ============================================================
log "Attaching ILM policy to index templates..."

# metrics template — named dynamic templates + ILM policy
METRICS_TEMPLATE='{
  "index_patterns": ["metrics-*"],
  "data_stream": {},
  "priority": 150,
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0,
      "index.lifecycle.name": "poc-2h-delete"
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
  log "  metrics-otel template updated: OK"
else
  warn "  metrics-otel template update: unexpected response"
fi

# logs and traces templates — all_strings_as_keyword + ILM policy
for signal in logs traces; do
  RESULT=$(es_cmd PUT "/_index_template/${signal}-otel" "{
    \"index_patterns\": [\"${signal}-*\"],
    \"data_stream\": {},
    \"priority\": 150,
    \"template\": {
      \"settings\": {
        \"number_of_shards\": 1,
        \"number_of_replicas\": 0,
        \"index.lifecycle.name\": \"poc-2h-delete\"
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
    log "  ${signal}-otel template updated: OK"
  else
    warn "  ${signal}-otel template update: unexpected response"
  fi
done

# ============================================================
# Apply ILM policy to any already-existing data streams
# New data streams will pick it up automatically from the template.
# Existing ones need an explicit settings update.
# ============================================================
log "Applying ILM policy to existing data streams..."

for signal in logs metrics traces; do
  INDEX="${signal}-generic.otel-default"
  STATUS=$(es_cmd GET "/_cat/indices/${INDEX}?h=health" 2>/dev/null | tr -d '[:space:]')
  if [[ "${STATUS}" == "green" || "${STATUS}" == "yellow" ]]; then
    RESULT=$(es_cmd PUT "/${INDEX}/_settings" \
      '{"index.lifecycle.name": "poc-2h-delete"}' \
      | docker run --rm -i "${TOOLKIT_IMAGE}" jq -r '.acknowledged')
    if [[ "${RESULT}" == "true" ]]; then
      log "  ${INDEX}: ILM policy applied"
    else
      warn "  ${INDEX}: settings update returned unexpected response"
    fi
  else
    log "  ${INDEX}: not yet created — ILM will apply on first write via template"
  fi
done

# ============================================================
# Verify ILM policy is in place
# ============================================================
log "Verifying ILM policy..."
POLICY_EXISTS=$(es_cmd GET "/_ilm/policy/poc-2h-delete" \
  | docker run --rm -i "${TOOLKIT_IMAGE}" \
    jq -r '.["poc-2h-delete"] | .policy.phases.delete | has("actions")' 2>/dev/null)

if [[ "${POLICY_EXISTS}" == "true" ]]; then
  log "ILM policy poc-2h-delete verified"
else
  warn "Could not verify ILM policy — check ES manually"
fi

# ============================================================
# Summary
# ============================================================
echo ""
log "ILM retention init complete."
echo ""
log "Policy:      poc-2h-delete"
log "Retention:   2 hours (hot rollover at 2h or 500mb, delete immediately after)"
log "Applies to:  logs-generic.otel-default"
log "             metrics-generic.otel-default"
log "             traces-generic.otel-default"
echo ""
log "Verify in Kibana: Stack Management → Index Lifecycle Policies → poc-2h-delete"
log "Check ILM status: curl -sk -u elastic:\$(es-pass) https://127.0.0.1:9200/_cat/indices?v | grep generic.otel"
echo ""
warn "Note: existing data older than 2h will be deleted on the next ILM evaluation cycle (~10 min)"
warn "To immediately free space, delete bloated data streams manually:"
warn "  curl -sk -u elastic:\$(es-pass) -X DELETE https://127.0.0.1:9200/_data_stream/logs-generic.otel-default"
