#!/bin/bash
set -euo pipefail

echo "=== Configuring rossoctl agent namespaces ==="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROSSOCTL_PROFILES="${SCRIPT_DIR}/usecases/services/rossoctl/profiles"
OPENAI_ENV="${SCRIPT_DIR}/usecases/services/rossoctl/manifests/llm-config/openai.env"

read -r -p "Update the Rossoctl openai.env file from OPENAI_API_KEY? [y/N] " REPLY
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
  if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "Error: OPENAI_API_KEY is not set; cannot update the Rossoctl openai.env file."
    exit 1
  fi
  printf 'apikey=%s\n' "$OPENAI_API_KEY" > "$OPENAI_ENV"
  echo "Updated the gitignored Rossoctl openai.env file."
else
  echo "Leaving the Rossoctl openai.env file unchanged."
fi

if [ ! -f "${OPENAI_ENV}" ]; then
  echo "Error: ${OPENAI_ENV} not found."
  echo "Create it with: echo 'apikey=<your-openai-api-key>' > ${OPENAI_ENV}"
  exit 1
fi
IFS='=' read -r openai_key_name rossoctl_openai_api_key < "$OPENAI_ENV"
if [ "$openai_key_name" != "apikey" ] || [ -z "$rossoctl_openai_api_key" ] || [ "$rossoctl_openai_api_key" = "CHANGE_ME" ]; then
  echo "Error: $OPENAI_ENV must contain a non-placeholder apikey value."
  exit 1
fi

for team in team1 team2; do
  echo ""
  echo "--- Applying to namespace: ${team} ---"
  oc apply -k "${ROSSOCTL_PROFILES}/${team}/"
done

echo ""
echo "Waiting for deployments to be available..."
for team in team1 team2; do
  oc wait --for=condition=available deployment/weather-tool -n "${team}" --timeout=120s 2>/dev/null || echo "  weather-tool in ${team}: not ready yet"
  oc wait --for=condition=available deployment/a2a-currency-converter -n "${team}" --timeout=120s 2>/dev/null || echo "  currency-converter in ${team}: not ready yet"
done

echo ""
echo "=== Phase 2: Rossoctl post-agent-setup (AgentRuntime CRs, authbridge config, secrets) ==="
ROSSOCTL_REPO="${ROSSOCTL_REPO:-${SCRIPT_DIR}/../../kagenti/kagenti}"
if [ -x "${ROSSOCTL_REPO}/scripts/ocp/setup-rossoctl.sh" ]; then
  "${ROSSOCTL_REPO}/scripts/ocp/setup-rossoctl.sh" --post-agent-setup --rossoctl-repo "${ROSSOCTL_REPO}"
else
  echo "Warning: rossoctl repo not found at ${ROSSOCTL_REPO}"
  echo "Set ROSSOCTL_REPO to the path of your rossoctl checkout, then re-run:"
  echo "  ROSSOCTL_REPO=/path/to/rossoctl ${SCRIPT_DIR}/deploy-kagenti-llm-config.sh"
fi

echo ""
echo "=== Rossoctl config complete ==="
echo "Per namespace (team1, team2):"
echo "  ConfigMap  'llamastack-env'         — LLM_API_BASE + LLM_MODEL"
echo "  Secret     'openai-secret'          — apikey"
echo "  Tool       'weather-tool-mcp'       — MCP weather tool (port 8000)"
echo "  Agent      'a2a-currency-converter' — LangGraph currency agent (port 8080)"
