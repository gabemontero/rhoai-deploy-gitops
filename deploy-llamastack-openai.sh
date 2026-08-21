#!/bin/bash
set -euo pipefail

echo "=== Phase 1: Prerequisite operators (cert-manager, jobset, rhoai) ==="
oc apply -k components/operators/cert-manager/
oc apply -k components/operators/jobset-operator/
oc apply -k components/operators/rhoai-operator/

echo ""
echo "Waiting for operators to reach Succeeded..."
while true; do
  statuses=$(oc get csv -A --no-headers 2>/dev/null | grep -E 'cert-manager|jobset|rhods' || true)
  count=$(echo "$statuses" | grep -c "Succeeded" || true)
  total=$(echo "$statuses" | grep -c -E 'cert-manager|jobset|rhods' || true)
  echo "  $count/$total operators Succeeded"
  if [ "$count" -ge 3 ] 2>/dev/null; then
    break
  fi
  sleep 15
done
echo "All operators ready."

echo ""
echo "=== Phase 2: DSC — dashboard + OGX ==="
oc apply -k components/instances/rhoai-instance/overlays/llamastack-only/

echo "Waiting for DataScienceCluster to be ready..."
oc wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True \
  datasciencecluster/default-dsc --timeout=600s
echo "DSC ready."

echo "Waiting for OGXServer CRD to be available..."
for i in $(seq 1 24); do
  if oc get crd ogxservers.ogx.io &>/dev/null; then
    echo "OGXServer CRD ready."
    break
  fi
  echo "  attempt $i/24 — CRD not yet available, waiting 10s..."
  sleep 10
done
if ! oc get crd ogxservers.ogx.io &>/dev/null; then
  echo "Error: OGXServer CRD not available after 4 minutes."
  exit 1
fi

echo "Waiting for OGX operator webhook to be ready..."
for i in $(seq 1 24); do
  endpoints=$(oc get endpoints -n redhat-ods-applications ogx-k8s-operator-webhook-service -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
  if [ -n "$endpoints" ]; then
    echo "OGX operator webhook ready (endpoints: $endpoints)"
    break
  fi
  echo "  attempt $i/24 — webhook endpoints not ready, waiting 10s..."
  sleep 10
done
if [ -z "$endpoints" ]; then
  echo "Warning: OGX webhook endpoints not ready after 4 minutes. Proceeding anyway..."
fi

echo ""
echo "=== Phase 3: LlamaStack instance (pointed at OpenAI) ==="

if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "Error: OPENAI_API_KEY environment variable is not set."
  echo "  Set it in your shell (e.g. in ~/.bashrc) and re-run."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENAI_ENV="${SCRIPT_DIR}/usecases/services/llamastack/manifests/openai-credentials/openai.env"
echo "api-key=${OPENAI_API_KEY}" > "$OPENAI_ENV"
echo "Populated openai.env from \$OPENAI_API_KEY."

oc apply -k usecases/services/llamastack/profiles/openai-only/

echo ""
echo "Waiting for patch-openai-credentials job to complete..."
oc wait --for=condition=complete job/patch-openai-credentials -n llamastack --timeout=600s

echo "Ensuring llama-stack-secret has OPENAI_API_KEY, VLLM_API_TOKEN, and correct INFERENCE_MODEL..."
oc patch secret llama-stack-secret -n llamastack \
  -p "{\"stringData\":{\"OPENAI_API_KEY\":\"${OPENAI_API_KEY}\",\"VLLM_API_TOKEN\":\"${OPENAI_API_KEY}\",\"VLLM_EMBEDDING_API_TOKEN\":\"${OPENAI_API_KEY}\",\"INFERENCE_MODEL\":\"openai/vllm-inference/gpt-4.1\"}}"

echo ""
echo "Waiting for LlamaStack deployment to be available..."
for i in $(seq 1 30); do
  dep_name=$(oc get deployment -n llamastack -l app.kubernetes.io/managed-by=ogx-operator --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
  if [ -z "$dep_name" ]; then
    dep_name=$(oc get deployment -n llamastack --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -v postgres | head -1)
  fi
  if [ -n "$dep_name" ]; then
    echo "Found deployment: $dep_name"
    echo "Restarting deployment to ensure it picks up the patched secret..."
    oc rollout restart "deployment/$dep_name" -n llamastack
    oc rollout status "deployment/$dep_name" -n llamastack --timeout=300s
    echo "LlamaStack deployment ready."
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "Error: No llamastack deployment found after 5 minutes."
    exit 1
  fi
  echo "  attempt $i/30 — no OGX deployment yet, waiting 10s..."
  sleep 10
done

echo ""
echo "Waiting for route to be created (up to 2 minutes)..."
route_created=false
for i in $(seq 1 12); do
  route_name=$(oc get route -n llamastack --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
  if [ -n "$route_name" ]; then
    route_created=true
    break
  fi
  echo "  attempt $i/12 — no route yet, waiting 10s..."
  sleep 10
done

if [ "$route_created" = false ]; then
  echo "Operator did not create route — creating it manually."
  svc_name=$(oc get svc -n llamastack --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -v postgres | head -1)
  svc_name="${svc_name:-llamastack-service}"
  oc create route edge llamastack --service="$svc_name" --port=8321 -n llamastack
  route_name="llamastack"
fi

echo ""
echo "=== RHOAI + LlamaStack deployment complete ==="
ROUTE_HOST=$(oc get route "$route_name" -n llamastack -o jsonpath='{.spec.host}')
echo "LlamaStack route: https://${ROUTE_HOST}"
echo "In-cluster URL:   http://${svc_name:-llamastack-service}.llamastack.svc.cluster.local:8321"

echo ""
echo "=== Phase 4: Register MCP tools in LlamaStack ==="
"${SCRIPT_DIR}/register-llamastack-tools.sh"

echo ""
echo "=== Phase 5: Rossoctl agent namespace LLM config ==="
if oc get namespace rossoctl-system &>/dev/null; then
  "${SCRIPT_DIR}/deploy-kagenti-llm-config.sh"
else
  echo "rossoctl-system namespace not found — skipping rossoctl LLM config."
  echo "Run deploy-kagenti-llm-config.sh after installing rossoctl."
fi
