#!/bin/bash
set -euo pipefail

echo "=== Configuring kagenti agent namespaces ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAGENTI_PROFILES="${SCRIPT_DIR}/usecases/services/kagenti/profiles"
OPENAI_ENV="${SCRIPT_DIR}/usecases/services/kagenti/manifests/llm-config/openai.env"

if [ ! -f "${OPENAI_ENV}" ]; then
  echo "Error: ${OPENAI_ENV} not found."
  echo "Create it with: echo 'apikey=<your-openai-api-key>' > ${OPENAI_ENV}"
  exit 1
fi

for team in team1 team2; do
  echo ""
  echo "--- Applying to namespace: ${team} ---"
  oc apply -k "${KAGENTI_PROFILES}/${team}/"
done

echo ""
echo "Waiting for deployments to be available..."
for team in team1 team2; do
  oc wait --for=condition=available deployment/weather-tool -n "${team}" --timeout=120s 2>/dev/null || echo "  weather-tool in ${team}: not ready yet"
  oc wait --for=condition=available deployment/a2a-currency-converter -n "${team}" --timeout=120s 2>/dev/null || echo "  currency-converter in ${team}: not ready yet"
done

echo ""
echo "=== Kagenti config complete ==="
echo "Per namespace (team1, team2):"
echo "  ConfigMap  'llamastack-env'         — LLM_API_BASE + LLM_MODEL"
echo "  Secret     'openai-secret'          — apikey"
echo "  Tool       'weather-tool-mcp'       — MCP weather tool (port 8000)"
echo "  Agent      'a2a-currency-converter' — LangGraph currency agent (port 8080)"
