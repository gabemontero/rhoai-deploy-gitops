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
echo "=== Phase 2: DSC — dashboard + llamastackoperator ==="
oc apply -k components/instances/rhoai-instance/overlays/llamastack-only/

echo "Waiting for DataScienceCluster to be ready..."
oc wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True \
  datasciencecluster/default-dsc --timeout=600s
echo "DSC ready."

echo ""
echo "=== Phase 3: LlamaStack instance (pointed at OpenAI) ==="
oc apply -k usecases/services/llamastack/profiles/openai-only/

echo ""
echo "Waiting for patch-openai-credentials job to complete..."
oc wait --for=condition=complete job/patch-openai-credentials -n llamastack --timeout=600s

echo ""
echo "=== Deployment complete ==="
echo "LlamaStack endpoint:"
oc get route llamastack -n llamastack -o jsonpath='{.spec.host}' 2>/dev/null && echo "" || echo "  (route not yet available — check: oc get route -n llamastack)"
