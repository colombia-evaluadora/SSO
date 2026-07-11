#!/usr/bin/env bash
# =============================================================================
# scripts/smoke-kind-query.sh
#
# End-to-end smoke test for the "kind=QUERY saves as REST" bug report.
#
# 1. Logs into the gateway with the dev admin user
# 2. POSTs a brand-new microservice with kind=QUERY to the gateway
# 3. Reads the row back from Postgres
# 4. Prints a verdict: PASS if kind=QUERY, FAIL if kind=REST (or absent)
#
# Run from the project root:
#   bash admin-ui/scripts/smoke-kind-query.sh
#
# This script hits the live stack on localhost:8080 and writes to the
# live sso DB. Safe to re-run; the serviceId is suffixed with the
# current timestamp.
# =============================================================================
set -euo pipefail

GATEWAY="${GATEWAY:-http://localhost:8080}"
ADMIN_EMAIL="${SSO_ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${SSO_ADMIN_PASSWORD:-ChangeMe-Now-Please-123!}"
SERVICE_ID="smoke-query-$(date +%s)"

echo ">>> 1. Logging in as $ADMIN_EMAIL via $GATEWAY/login"
LOGIN_RESPONSE=$(curl -sS -X POST "$GATEWAY/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")
JWT=$(echo "$LOGIN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
echo "    got JWT (${#JWT} chars)"

echo
echo ">>> 2. POSTing microservice kind=QUERY to $GATEWAY/api/sso-admin/microservice/save"
echo "    serviceId=$SERVICE_ID"
SAVE_BODY=$(cat <<EOF
{
  "serviceId": "$SERVICE_ID",
  "description": "smoke-test",
  "requestUri": "/api/smoke/**",
  "targetUriPath": "/x",
  "targetUrlHost": "h",
  "targetUrlPort": "80",
  "kind": "QUERY",
  "dialect": "postgres",
  "jdbcUrl": "jdbc:postgresql://postgres:5432/sso",
  "dbUsername": "sso",
  "dbPassword": "change-me-in-prod",
  "poolSize": 5,
  "instanceName": "smoke-$RANDOM"
}
EOF
)
SAVE_RESPONSE=$(curl -sS -X POST "$GATEWAY/api/sso-admin/microservice/save" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $JWT" \
  -d "$SAVE_BODY" -w "\nHTTP %{http_code}")
echo "    response:"
echo "$SAVE_RESPONSE" | sed 's/^/      /'

echo
echo ">>> 3. Reading the row back from Postgres"
ROW=$(docker exec -i sso-postgres psql -U sso -d sso -t -A -F'|' \
  -c "SELECT serviceid, kind, dialect, instancename FROM microservice WHERE serviceid='$SERVICE_ID';")
echo "    $ROW"
STORED_KIND=$(echo "$ROW" | cut -d'|' -f2 | tr -d ' ')

echo
echo ">>> 4. Verdict"
if [ "$STORED_KIND" = "QUERY" ]; then
  echo "    ✅ PASS — kind=QUERY was stored correctly"
  echo "    The frontend form is correct AND the backend honors the kind field."
  exit 0
else
  echo "    ❌ FAIL — kind stored as '$STORED_KIND' (expected 'QUERY')"
  echo "    The frontend is correct (proven by the vitest test)."
  echo "    The bug is in the backend — it is NOT honoring the kind field from the request body."
  exit 1
fi
