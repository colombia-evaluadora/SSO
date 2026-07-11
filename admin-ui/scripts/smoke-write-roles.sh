#!/usr/bin/env bash
# =============================================================================
# scripts/smoke-write-roles.sh
#
# End-to-end smoke for the WriteDefinitionAdminService.RoleChecked
# contract. The pattern is identical to smoke-query-roles.sh —
# the backend record is being audited for the same
# `id` → `roleId` + `bound` → `checked` rename that hit
# AppService (commit 99c56cd) and QueryAdminService (909d009).
#
# The frontend currently has NO consumer for write-definition
# bindings (no /admin/writes page renders this endpoint yet).
# This smoke is preventive: it asserts the contract NOW so when
# the page is built, the response shape is already
# `roleId` + `checked` and the frontend type can follow the
# module convention without surprises.
#
# Flow:
#  1. Login
#  2. Self-seed: POST /write/save (no row exists by default)
#  3. POST /write/{id}/role/{roleId} → 204
#  4. GET  /write/{id}/roles/checked → assert shape:
#        - 'roleId' field present
#        - 'checked' field present
#        - NO bare 'id' field
#        - NO 'bound' flag
#        - role has checked=true after bind
#  5. Verify Postgres row in role_write
#  6. DELETE /write/{id}/role/{roleId} → 204
#  7. GET /roles/checked → checked=false
#  8. Cleanup: DELETE /write/{id}
#  9. PASS / FAIL
#
# Run from project root:
#   bash admin-ui/scripts/smoke-write-roles.sh
# =============================================================================
set -euo pipefail

GATEWAY="${GATEWAY:-http://localhost:8080}"
ADMIN_EMAIL="${SSO_ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${SSO_ADMIN_PASSWORD:-ChangeMe-Now-Please-123!}"
SUFFIX=$(date +%s)

PASS=0
FAIL=0
ok()   { echo "    ✅ $*"; PASS=$((PASS+1)); }
bad()  { echo "    ❌ $*"; FAIL=$((FAIL+1)); }
info() { echo "    $*"; }
hr()   { echo "------------------------------------------------------------"; }

psql_q() {
  docker exec -i sso-postgres psql -U sso -d sso -t -A -F'|' -c "$1" \
    | sed '/^$/d' | sed 's/^ *//; s/ *$//'
}

assert_http() {
  if [ "$1" = "$2" ]; then
    ok "$3 (HTTP $2)"
  else
    bad "$3 — expected HTTP $1, got HTTP $2"
  fi
}

# ---------- 1. login ----------
hr
echo ">>> 1. Logging in as $ADMIN_EMAIL via $GATEWAY/login"
LOGIN_RESPONSE=$(curl -sS -X POST "$GATEWAY/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")
JWT=$(echo "$LOGIN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
info "got JWT (${#JWT} chars)"
AUTH=(-H "Authorization: Bearer $JWT" -H "Content-Type: application/json")

# ---------- 2. self-seed a write definition ----------
hr
echo ">>> 2. POSTing a self-seeded write definition"

UUID="smoke-write-$SUFFIX"

# Look up any kind=QUERY instance so we can exercise the new
# microserviceId binding. The smoke just needs a row that the
# service will accept; resolveWriteMicroservice rejects REST
# rows with 400 INVALID_REQUEST, so a non-QUERY won't work.
# In dev databases the legacy name was `postgres`; in others
# the instance name is unique-per-flow (e.g. `prueba2`). We
# pick the lowest-id QUERY row to stay deterministic.
MS_ID=$(psql_q "SELECT ID_MICROSERVICE FROM MICROSERVICE
                WHERE KIND = 'QUERY'
                ORDER BY ID_MICROSERVICE ASC
                LIMIT 1;" | head -1)
if [ -z "$MS_ID" ]; then
  bad "no MICROSERVICE row with KIND=QUERY — provision one before running this smoke"
  hr; echo "0 / 0 checks passed (skipped)"; exit 1
fi
info "kind=QUERY microservice id = $MS_ID"

# Include microserviceId so the FK binding actually exercises
# WriteDefinitionAdminService.copy → resolveWriteMicroservice.
# null would be a no-op and we'd never catch a regression where
# the column is silently dropped on the wire.
CREATE_BODY=$(cat <<EOF
{
  "uuid": "$UUID",
  "writeType": "INSERT",
  "tableName": "public.smoke_dummy_$SUFFIX",
  "columns": "[\"ID\"]",
  "keyColumns": null,
  "microserviceId": $MS_ID
}
EOF
)
CREATE_HTTP=$(curl -sS -o /tmp/smoke-write-create.json -w "%{http_code}" \
  -X POST "$GATEWAY/api/sso-admin/write/save" "${AUTH[@]}" -d "$CREATE_BODY")
assert_http 201 "$CREATE_HTTP" "create write definition"

WRITE_ID=$(python3 -c "import json; print(json.load(open('/tmp/smoke-write-create.json'))['id'])")
info "new write id = $WRITE_ID"

# The response must echo the binding so the admin UI can render
# it on the writes table without a second round-trip.
ECHOED_MS=$(python3 -c "
import json
d = json.load(open('/tmp/smoke-write-create.json'))
print(d.get('microserviceId') if d.get('microserviceId') is not None else 'null')
")
if [ "$ECHOED_MS" = "$MS_ID" ]; then
  ok "create response carries microserviceId=$MS_ID (WriteDefinitionResponse.fromEntity)"
else
  bad "create response microserviceId mismatch — got '$ECHOED_MS', expected '$MS_ID'"
fi

# Ensure known-clean starting state for the role we'll bind.
ROLE_ID=$(psql_q "SELECT id_role FROM role ORDER BY id_role LIMIT 1;" | head -1)
if [ -z "$ROLE_ID" ]; then
  bad "no role row in DB — cannot exercise role binding"
  curl -sS -o /dev/null -X DELETE "$GATEWAY/api/sso-admin/write/$WRITE_ID" "${AUTH[@]}"
  exit 1
fi
info "role id = $ROLE_ID"
psql_q "DELETE FROM role_write WHERE write_definition_id=$WRITE_ID AND role_id=$ROLE_ID;" >/dev/null

# Register cleanup so we don't leak rows if the script aborts.
cleanup() {
  curl -sS -o /dev/null -X DELETE "$GATEWAY/api/sso-admin/write/$WRITE_ID" "${AUTH[@]}" || true
}
trap cleanup EXIT

# ---------- 3. bind ----------
hr
echo ">>> 3. POSTing bind /write/$WRITE_ID/role/$ROLE_ID"
BIND_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
  -X POST "$GATEWAY/api/sso-admin/write/$WRITE_ID/role/$ROLE_ID" "${AUTH[@]}")
assert_http 204 "$BIND_HTTP" "bind role $ROLE_ID to write $WRITE_ID"

# ---------- 4. JSON shape ----------
hr
echo ">>> 4. GET /write/$WRITE_ID/roles/checked — shape + flag"
CHECKED=$(curl -sS "$GATEWAY/api/sso-admin/write/$WRITE_ID/roles/checked" "${AUTH[@]}")

# 4a. roleId field present
HAS_ROLEID=$(echo "$CHECKED" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print('yes' if data and 'roleId' in data[0] else 'no')
")
[ "$HAS_ROLEID" = "yes" ] \
  && ok "/roles/checked response uses 'roleId' field (matches module convention)" \
  || bad "/roles/checked response uses bare 'id'"

# 4b. checked flag present
HAS_CHECKED=$(echo "$CHECKED" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print('yes' if data and 'checked' in data[0] else 'no')
")
[ "$HAS_CHECKED" = "yes" ] \
  && ok "/roles/checked response uses 'checked' field (matches module convention)" \
  || bad "/roles/checked response uses 'bound'"

# 4c. No bare `id` field
NO_BARE_ID=$(echo "$CHECKED" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print('yes' if not data or 'id' not in data[0] else 'no')
")
[ "$NO_BARE_ID" = "yes" ] \
  && ok "/roles/checked response has NO bare 'id' field" \
  || bad "/roles/checked response has both 'id' and 'roleId'"

# 4d. checked=true on the bound role
MATCH=$(echo "$CHECKED" | python3 -c "
import sys, json
data = json.load(sys.stdin)
match = [r for r in data if str(r.get('roleId')) == '$ROLE_ID']
print('yes' if match and match[0].get('checked') is True else 'no')
")
[ "$MATCH" = "yes" ] \
  && ok "role $ROLE_ID has checked=true after bind" \
  || bad "role $ROLE_ID does NOT have checked=true after bind"

# 4e. Postgres row in role_write
PG_ROW=$(psql_q "SELECT 1 FROM role_write WHERE write_definition_id=$WRITE_ID AND role_id=$ROLE_ID;")
[ -n "$PG_ROW" ] \
  && ok "row in role_write for write=$WRITE_ID role=$ROLE_ID" \
  || bad "no row in role_write — bind did not persist"

# ---------- 5. unbind ----------
hr
echo ">>> 5. DELETE /write/$WRITE_ID/role/$ROLE_ID"
UNBIND_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
  -X DELETE "$GATEWAY/api/sso-admin/write/$WRITE_ID/role/$ROLE_ID" "${AUTH[@]}")
assert_http 204 "$UNBIND_HTTP" "unbind role $ROLE_ID from write $WRITE_ID"

# ---------- 6. checked flips back ----------
hr
echo ">>> 6. GET /roles/checked after unbind"
CHECKED2=$(curl -sS "$GATEWAY/api/sso-admin/write/$WRITE_ID/roles/checked" "${AUTH[@]}")
MATCH2=$(echo "$CHECKED2" | python3 -c "
import sys, json
data = json.load(sys.stdin)
match = [r for r in data if str(r.get('roleId')) == '$ROLE_ID']
print('yes' if match and match[0].get('checked') is False else 'no')
")
[ "$MATCH2" = "yes" ] \
  && ok "role $ROLE_ID has checked=false after unbind" \
  || bad "role $ROLE_ID does NOT flip to checked=false after unbind"

PG_GONE=$(psql_q "SELECT 1 FROM role_write WHERE write_definition_id=$WRITE_ID AND role_id=$ROLE_ID;")
[ -z "$PG_GONE" ] \
  && ok "role_write row removed" \
  || bad "role_write row still present after unbind"

# Assert the FK column actually persisted on the way out before
# we tear the row down. The 07- migration adds MICROSERVICE_ID;
# this guards against a regression where the field is dropped
# server-side (e.g. someone removes `w.setMicroservice(...)`
# from copy()). Must run BEFORE the DELETE below or the row
# is already gone.
PG_FK=$(psql_q "SELECT microservice_id FROM write_definition WHERE id_write_definition=$WRITE_ID;")
[ "$PG_FK" = "$MS_ID" ] \
  && ok "write_definition.MICROSERVICE_ID persisted as $MS_ID" \
  || bad "write_definition.MICROSERVICE_ID missing or wrong — got '$PG_FK'"

# Cleanup also runs via trap, but do it explicitly to verify.
DEL_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
  -X DELETE "$GATEWAY/api/sso-admin/write/$WRITE_ID" "${AUTH[@]}")
assert_http 204 "$DEL_HTTP" "DELETE /write/{id}"

PG_W=$(psql_q "SELECT 1 FROM write_definition WHERE id_write_definition=$WRITE_ID;")
[ -z "$PG_W" ] \
  && ok "write_definition row removed" \
  || bad "write_definition row still present"

# Disable the trap — we already cleaned up explicitly.
trap - EXIT

# ---------- 7. verdict ----------
hr
echo ">>> 7. Verdict"
TOTAL=$((PASS + FAIL))
echo "    $PASS / $TOTAL checks passed"
if [ "$FAIL" -eq 0 ]; then
  echo "    ✅ PASS — WriteDefinitionAdminService.RoleChecked contract matches module convention"
  exit 0
else
  echo "    ❌ FAIL — $FAIL check(s) failed. Inspect logs above."
  exit 1
fi