#!/bin/bash
set -euo pipefail

echo "=== Assigning rossoctl-operator role to agent SPIFFE clients ==="

KEYCLOAK_NS="${KEYCLOAK_NS:-keycloak}"
ROSSOCTL_REALM="${ROSSOCTL_REALM:-rossoctl}"
ROLE_NAME="${ROLE_NAME:-rossoctl-operator}"

# Derive cluster apps domain from the keycloak route
KEYCLOAK_HOST=$(oc get routes -n "${KEYCLOAK_NS}" -o jsonpath='{.items[0].spec.host}')
APPS_DOMAIN=$(echo "$KEYCLOAK_HOST" | sed 's/^[^.]*\.//')
echo "Keycloak: ${KEYCLOAK_HOST}"
echo "Apps domain: ${APPS_DOMAIN}"

# Get admin credentials and token
ADMIN_USER=$(oc get secret keycloak-initial-admin -n "${KEYCLOAK_NS}" -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PASS=$(oc get secret keycloak-initial-admin -n "${KEYCLOAK_NS}" -o jsonpath='{.data.password}' | base64 -d)

echo "Waiting for keycloak route to be reachable..."
for i in $(seq 1 12); do
  TOKEN_RESPONSE=$(curl -sk "https://${KEYCLOAK_HOST}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "username=${ADMIN_USER}" \
    -d "password=${ADMIN_PASS}" \
    -d "grant_type=password" 2>/dev/null || true)
  if [ -n "$TOKEN_RESPONSE" ]; then
    TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null || true)
    if [ -n "$TOKEN" ]; then
      break
    fi
    echo "  attempt $i/12 — keycloak responded but no token ($(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','unknown'))" 2>/dev/null || echo 'parse error'))"
  else
    echo "  attempt $i/12 — no response, waiting 10s..."
  fi
  sleep 10
done

if [ -z "${TOKEN:-}" ]; then
  echo "Error: failed to obtain keycloak admin token after 12 attempts"
  exit 1
fi

# Get or create the rossoctl-operator role
ROLE_JSON=$(curl -sk "https://${KEYCLOAK_HOST}/admin/realms/${ROSSOCTL_REALM}/roles/${ROLE_NAME}" \
  -H "Authorization: Bearer $TOKEN")
ROLE_ID=$(echo "$ROLE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)

if [ -z "$ROLE_ID" ]; then
  echo "Role '${ROLE_NAME}' not found — creating it..."
  CREATE_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST \
    "https://${KEYCLOAK_HOST}/admin/realms/${ROSSOCTL_REALM}/roles" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${ROLE_NAME}\",\"description\":\"Operator role for rossoctl agents\"}")
  if [ "$CREATE_CODE" = "201" ] || [ "$CREATE_CODE" = "409" ]; then
    echo "  Role created (HTTP ${CREATE_CODE})"
  else
    echo "Error: failed to create role '${ROLE_NAME}' (HTTP ${CREATE_CODE})"
    exit 1
  fi
  ROLE_JSON=$(curl -sk "https://${KEYCLOAK_HOST}/admin/realms/${ROSSOCTL_REALM}/roles/${ROLE_NAME}" \
    -H "Authorization: Bearer $TOKEN")
  ROLE_ID=$(echo "$ROLE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)
  if [ -z "$ROLE_ID" ]; then
    echo "Error: role '${ROLE_NAME}' still not found after creation attempt"
    exit 1
  fi
fi
echo "Role: ${ROLE_NAME} (${ROLE_ID})"

ROLE_PAYLOAD="[{\"id\":\"${ROLE_ID}\",\"name\":\"${ROLE_NAME}\"}]"

# Get all clients and find SPIFFE-based agent clients
echo ""
ALL_CLIENTS=$(curl -sk "https://${KEYCLOAK_HOST}/admin/realms/${ROSSOCTL_REALM}/clients" \
  -H "Authorization: Bearer $TOKEN")

SPIFFE_CLIENTS=$(echo "$ALL_CLIENTS" | python3 -c "
import sys, json
clients = json.load(sys.stdin)
for c in clients:
    cid = c.get('clientId', '')
    if cid.startswith('spiffe://') and '/ns/' in cid and '/sa/' in cid:
        print(f'{c[\"id\"]}|{cid}')
")

if [ -z "$SPIFFE_CLIENTS" ]; then
  echo "No SPIFFE agent clients found — agents may not have been deployed yet."
  echo "Deploy agents first, then re-run this script."
  exit 0
fi

while IFS='|' read -r client_uuid client_id; do
  ns=$(echo "$client_id" | sed 's|.*/ns/||; s|/sa/.*||')
  sa=$(echo "$client_id" | sed 's|.*/sa/||')

  # Get service account user
  SA_USER=$(curl -sk "https://${KEYCLOAK_HOST}/admin/realms/${ROSSOCTL_REALM}/clients/${client_uuid}/service-account-user" \
    -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)

  # Check if role already assigned
  EXISTING=$(curl -sk "https://${KEYCLOAK_HOST}/admin/realms/${ROSSOCTL_REALM}/users/${SA_USER}/role-mappings/realm" \
    -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    if r['name'] == '${ROLE_NAME}':
        print('yes')
        break
" 2>/dev/null)

  if [ "$EXISTING" = "yes" ]; then
    echo "  ${ns}/${sa} — already has ${ROLE_NAME}, skipping"
    continue
  fi

  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST \
    "https://${KEYCLOAK_HOST}/admin/realms/${ROSSOCTL_REALM}/users/${SA_USER}/role-mappings/realm" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "${ROLE_PAYLOAD}")

  if [ "$HTTP_CODE" = "204" ]; then
    echo "  ${ns}/${sa} — assigned ${ROLE_NAME}"
  else
    echo "  ${ns}/${sa} — FAILED (HTTP ${HTTP_CODE})"
  fi
done <<< "$SPIFFE_CLIENTS"

echo ""
echo "=== Keycloak role assignment complete ==="
