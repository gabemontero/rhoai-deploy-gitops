#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLAMASTACK_OPENAI_ENV="${SCRIPT_DIR}/usecases/services/llamastack/manifests/openai-credentials/openai.env"
ROSSOCTL_OPENAI_ENV="${SCRIPT_DIR}/usecases/services/rossoctl/manifests/llm-config/openai.env"

read -r -p "Update both openai.env files from OPENAI_API_KEY? [y/N] " REPLY
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
  if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "Error: OPENAI_API_KEY is not set; cannot update the openai.env files."
    exit 1
  fi
  printf 'api-key=%s\n' "$OPENAI_API_KEY" > "$LLAMASTACK_OPENAI_ENV"
  printf 'apikey=%s\n' "$OPENAI_API_KEY" > "$ROSSOCTL_OPENAI_ENV"
  echo "Updated both gitignored openai.env files."
else
  echo "Leaving both openai.env files unchanged."
fi

if [ ! -f "$LLAMASTACK_OPENAI_ENV" ]; then
  echo "Error: $LLAMASTACK_OPENAI_ENV not found."
  exit 1
fi
IFS='=' read -r openai_key_name deployment_openai_api_key < "$LLAMASTACK_OPENAI_ENV"
if [ "$openai_key_name" != "api-key" ] || [ -z "$deployment_openai_api_key" ] || [ "$deployment_openai_api_key" = "CHANGE_ME" ]; then
  echo "Error: $LLAMASTACK_OPENAI_ENV must contain a non-placeholder api-key value."
  exit 1
fi

# This script is for deploying OGX to the dev cluster (redhat-ai-dev)
# which already has RHOAI installed with other components enabled.
# It patches the DataScienceCluster to add OGX without disrupting existing components.
#
# NOTE: This script skips cert-manager and jobset operators because:
#   - cert-manager: Not needed when KServe runs in Headless mode (uses OpenShift Routes for TLS)
#   - jobset: Only needed for Training Operator (disabled on dev cluster)

# Handle KUBECONFIG - ask user which cluster to use
if [ -n "${KUBECONFIG:-}" ]; then
  current_cluster=$(oc whoami --show-server 2>/dev/null || echo "unknown")
  echo "KUBECONFIG is set to: $KUBECONFIG"
  echo "Currently connected to: $current_cluster"
  echo ""
  read -p "Use this cluster? [Y/n] " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "Unsetting KUBECONFIG to use default ~/.kube/config"
    unset KUBECONFIG
    current_cluster=$(oc whoami --show-server 2>/dev/null || echo "unknown")
    echo "Now connected to: $current_cluster"
  else
    echo "Using cluster from KUBECONFIG"
  fi
else
  echo "Using default cluster from ~/.kube/config"
fi

echo ""
echo "=== Phase 1: RHOAI Upgrade (optional - may be handled separately) ==="
echo "Current RHOAI version:"
# Check both common namespaces for RHOAI operator
for ns in redhat-ods-operator openshift-operators; do
  if oc get csv -n "$ns" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -q rhods; then
    oc get csv -n "$ns" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep rhods
    break
  fi
done

read -p "Do you want to install or upgrade RHOAI on stable-3.x to 3.5.0? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo "Installing or upgrading RHOAI operator to 3.5.0 on stable-3.x..."
  echo "(Skipping cert-manager and jobset — not needed for Headless KServe + OGX-only deployment)"
  oc apply -k components/operators/rhoai-operator/

  echo ""
  echo "Waiting for RHOAI operator to reach Succeeded..."
  while true; do
    rhods_csv=""
    for ns in redhat-ods-operator openshift-operators; do
      csv=$(oc get csv -n "$ns" --no-headers 2>/dev/null | awk '$1 == "rhods-operator.3.5.0" {print; exit}')
      if [ -n "$csv" ]; then
        rhods_csv="$csv"
        break
      fi
    done
    if echo "$rhods_csv" | grep -q "Succeeded"; then
      echo "  RHOAI operator ready"
      break
    fi
    echo "  Waiting for rhods operator... (current: $(echo "$rhods_csv" | awk '{print $1, $NF}' || echo 'not found'))"
    sleep 15
  done
  echo "RHOAI operator upgrade complete."

  echo ""
  echo "New RHOAI version:"
  for ns in redhat-ods-operator openshift-operators; do
    if oc get csv -n "$ns" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -q rhods; then
      oc get csv -n "$ns" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep rhods
      break
    fi
  done
else
  echo "Skipping RHOAI upgrade. Ensure you're on RHOAI 3.5.0+ for OGX support."
  echo "Current version:"
  for ns in redhat-ods-operator openshift-operators; do
    if oc get csv -n "$ns" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -q rhods; then
      oc get csv -n "$ns" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep rhods
      break
    fi
  done
fi

echo ""
echo "=== Phase 2: Patch DataScienceCluster to enable OGX ==="

# Check if OGX component is available (requires RHOAI 3.5.0+)
if ! oc explain datasciencecluster.spec.components.ogx &>/dev/null; then
  echo "Error: OGX component not available in current RHOAI version."
  echo "  OGX requires RHOAI 3.5.0 or later."
  echo "  Please upgrade RHOAI first."
  exit 1
fi

echo "Patching DataScienceCluster to add OGX component (without disrupting other components)..."
oc patch datasciencecluster default-dsc --type=merge -p '{"spec":{"components":{"ogx":{"managementState":"Managed"}}}}'

echo "Waiting for DataScienceCluster to be ready..."
oc wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True \
  datasciencecluster/default-dsc --timeout=600s
echo "DSC ready."

echo "Waiting for OGXServer CRD to be available..."
for i in $(seq 1 24); do
  if oc get crd ogxservers.ogx.io &>/dev/null 2>&1; then
    echo "OGXServer CRD ready."
    break
  fi
  echo "  attempt $i/24 — CRD not yet available, waiting 10s..."
  sleep 10
done
if ! oc get crd ogxservers.ogx.io &>/dev/null 2>&1; then
  echo "Warning: OGXServer CRD not available after 4 minutes."
  echo "  Checking permissions..."
  oc auth can-i get crd || echo "  No permission to check CRDs. Proceeding anyway..."
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
echo "=== Phase 3: LlamaStack/OGX instance (pointed at OpenAI) ==="

oc apply -k usecases/services/llamastack/profiles/openai-only/

echo ""
echo "Waiting for patch-openai-credentials job to complete..."
oc wait --for=condition=complete job/patch-openai-credentials -n llamastack --timeout=600s

echo "Ensuring llama-stack-secret has OPENAI_API_KEY, VLLM_API_TOKEN, and correct INFERENCE_MODEL..."
oc patch secret llama-stack-secret -n llamastack \
  -p "{\"stringData\":{\"OPENAI_API_KEY\":\"${deployment_openai_api_key}\",\"VLLM_API_TOKEN\":\"${deployment_openai_api_key}\",\"VLLM_EMBEDDING_API_TOKEN\":\"${deployment_openai_api_key}\",\"INFERENCE_MODEL\":\"openai/vllm-inference/gpt-4.1\"}}"

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
