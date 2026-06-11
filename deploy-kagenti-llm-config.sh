#!/bin/bash
set -euo pipefail

echo "=== Configuring kagenti agent namespaces with LlamaStack LLM config ==="

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
  echo "--- Applying LLM config to namespace: ${team} ---"
  oc apply -k "${KAGENTI_PROFILES}/${team}/"
done

echo ""
echo "=== Kagenti LLM config complete ==="
echo "Agents in team1/team2 can now use:"
echo "  ConfigMap 'llamastack-env' — LLM_API_BASE + LLM_MODEL"
echo "  Secret 'openai-secret'     — apikey"
