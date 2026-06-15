#!/bin/bash
set -euo pipefail

echo "=== Registering MCP tools in LlamaStack ==="

LLAMASTACK_URL="${LLAMASTACK_URL:-http://llamastack-service.llamastack.svc.cluster.local:8321}"

register_mcp_tool() {
  local toolgroup_id="$1"
  local mcp_uri="$2"

  existing=$(oc exec -n llamastack deploy/llamastack -- \
    curl -s "${LLAMASTACK_URL}/v1/toolgroups" 2>/dev/null | \
    grep -o "\"${toolgroup_id}\"" || true)

  if [ -n "$existing" ]; then
    echo "  ${toolgroup_id} — already registered, skipping"
    return 0
  fi

  echo "  Registering ${toolgroup_id} -> ${mcp_uri}"
  oc exec -n llamastack deploy/llamastack -- \
    curl -s -X POST "${LLAMASTACK_URL}/v1/toolgroups" \
    -H "Content-Type: application/json" \
    -d "{
      \"toolgroup_id\": \"${toolgroup_id}\",
      \"provider_id\": \"model-context-protocol\",
      \"mcp_endpoint\": {
        \"uri\": \"${mcp_uri}\"
      }
    }" >/dev/null

  echo "  ${toolgroup_id} — registered"
}

echo ""
echo "Checking LlamaStack is reachable..."
oc exec -n llamastack deploy/llamastack -- \
  curl -sf "${LLAMASTACK_URL}/v1/health" >/dev/null 2>&1 || {
    echo "Error: LlamaStack not reachable at ${LLAMASTACK_URL}"
    exit 1
  }

echo ""
echo "--- MCP tool registrations ---"

register_mcp_tool "mcp::weather-tool" \
  "http://weather-tool-mcp.team1.svc.cluster.local:8000/mcp"

echo ""
echo "--- Verifying tool discovery ---"
for toolgroup in "mcp::weather-tool"; do
  tools=$(oc exec -n llamastack deploy/llamastack -- \
    curl -s "${LLAMASTACK_URL}/v1/tools?toolgroup_id=${toolgroup}" 2>/dev/null)
  count=$(echo "$tools" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo "0")
  echo "  ${toolgroup}: ${count} tool(s) discovered"
done

echo ""
echo "=== LlamaStack tool registration complete ==="
