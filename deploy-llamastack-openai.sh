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
echo "Waiting for LlamaStack deployment to be available..."
oc wait --for=condition=available deployment/llamastack -n llamastack --timeout=300s
echo "LlamaStack deployment ready."

echo ""
echo "Waiting for operator to create route (up to 2 minutes)..."
route_created=false
for i in $(seq 1 12); do
  if oc get route llamastack -n llamastack &>/dev/null; then
    route_created=true
    break
  fi
  echo "  attempt $i/12 — no route yet, waiting 10s..."
  sleep 10
done

if [ "$route_created" = false ]; then
  echo "Operator did not create route — creating it manually."
  oc create route edge llamastack --service=llamastack-service --port=8321 -n llamastack
fi

echo ""
echo "=== Deployment complete ==="
ROUTE_HOST=$(oc get route llamastack -n llamastack -o jsonpath='{.spec.host}')
echo "LlamaStack route: https://${ROUTE_HOST}"
echo "In-cluster URL:   http://llamastack-service.llamastack.svc.cluster.local:8321"
