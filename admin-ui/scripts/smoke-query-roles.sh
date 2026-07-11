#!/usr/bin/env bash
# =============================================================================
# scripts/smoke-query-roles.sh
#
# End-to-end smoke for the QueryAdminService.RoleChecked contract.
# The 4 binding families for App were tested in smoke-apps.sh;
# queries have only 1 binding family (role), so this is a tighter
# smoke. Its main job is to assert the JSON shape — the record was
# historically returning {id, name, bound} while the frontend type
# QueryRoleChecked expects {roleId, name, checked}, which caused
# the binding tab to render role-toggle-undefined and POST
# /query/{id}/role/undefined at runtime.
#
# 1. Logs in as admin
# 2. Looks up the first query and the first role from Postgres
# 3. POSTs /query/{queryId}/role/{roleId} → 204
# 4. GETs /query/{queryId}/roles/checked and asserts:
#      - shape is {roleId, name, checked} (not {id, name, bound})
#      - the bound role has checked=true
# 5. DELETEs /query/{queryId}/role/{roleId} → 204
# 6. GETs /query/{queryId}/roles/checked and asserts checked=false
# 7. Reads query_role table from Postgres to verify the row exists
#    after bind and is gone after unbind
# 8. Prints PASS / FAIL
#
# Run from the project root:
#   bash admin-ui/scripts/smoke-query-roles.sh
# =============================================================================
set -euo pipefail

GATEWAY="${GATEWAY:-http://localhost:8080}"
ADMIN_EMAIL="${SSO_ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${SSO_ADMIN_PASSWORD:-ChangeMe-Now-Please-123!}"

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

# ---------- 2. lookup real ids ----------
hr
echo ">>> 2. Looking up query id + role id from Postgres"
QUERY_ID=$(psql_q "SELECT id_query FROM QUERY ORDER BY id_query LIMIT 1;" | head -1)
ROLE_ID=$(psql_q "SELECT id_role FROM role ORDER BY id_role LIMIT 1;" | head -1)

if [ -z "$QUERY_ID" ]; then
  bad "no query row in DB — create one first via the UI or psql"
  hr; echo "0 / 0 checks passed (skipped)"; exit 1
fi
if [ -z "$ROLE_ID" ]; then
  bad "no role row in DB"
  hr; echo "0 / 0 checks passed (skipped)"; exit 1
fi
info "query id = $QUERY_ID"
info "role id  = $ROLE_ID"

# Make sure we start from a known-clean state for this pair.
psql_q "DELETE FROM ROLE_QUERY WHERE QUERY_ID=$QUERY_ID AND ROLE_ID=$ROLE_ID;" >/dev/null

# ---------- 3. bind ----------
hr
echo ">>> 3. POSTing bind /query/$QUERY_ID/role/$ROLE_ID"
BIND_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
  -X POST "$GATEWAY/api/sso-admin/query/$QUERY_ID/role/$ROLE_ID" "${AUTH[@]}")
assert_http 204 "$BIND_HTTP" "bind role $ROLE_ID to query $QUERY_ID"

# ---------- 4. JSON shape + checked flag ----------
hr
echo ">>> 4. GET /query/$QUERY_ID/roles/checked — shape + flag"
CHECKED=$(curl -sS "$GATEWAY/api/sso-admin/query/$QUERY_ID/roles/checked" "${AUTH[@]}")

# 4a. Field name = roleId (frontend reads row.roleId)
HAS_ROLEID=$(echo "$CHECKED" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print('yes' if data and 'roleId' in data[0] else 'no')
")
[ "$HAS_ROLEID" = "yes" ] \
  && ok "/roles/checked response uses 'roleId' field (matches frontend)" \
  || bad "/roles/checked response uses bare 'id' — frontend QueryRoleChecked.roleId would be undefined"

# 4b. Flag name = checked (frontend reads row.checked)
HAS_CHECKED=$(echo "$CHECKED" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print('yes' if data and 'checked' in data[0] else 'no')
")
[ "$HAS_CHECKED" = "yes" ] \
  && ok "/roles/checked response uses 'checked' field (matches frontend)" \
  || bad "/roles/checked response uses 'bound' — frontend QueryRoleChecked.checked would be undefined"

# 4c. No bare `id` lingering (would also break the frontend's
# `data-testid="role-toggle-\${r.roleId}"` since `id` would never
# be the rendered key)
NO_BARE_ID=$(echo "$CHECKED" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print('yes' if not data or 'id' not in data[0] else 'no')
")
[ "$NO_BARE_ID" = "yes" ] \
  && ok "/roles/checked response has NO bare 'id' field" \
  || bad "/roles/checked response has both 'id' and 'roleId' — confusing for parsers"

# 4d. The bound role has checked=true
MATCH=$(echo "$CHECKED" | python3 -c "
import sys, json
data = json.load(sys.stdin)
match = [r for r in data if str(r.get('roleId')) == '$ROLE_ID']
print('yes' if match and match[0].get('checked') is True else 'no')
")
[ "$MATCH" = "yes" ] \
  && ok "role $ROLE_ID has checked=true after bind" \
  || bad "role $ROLE_ID does NOT have checked=true after bind"

# 4e. Postgres has the row
PG_ROW=$(psql_q "SELECT 1 FROM ROLE_QUERY WHERE QUERY_ID=$QUERY_ID AND ROLE_ID=$ROLE_ID;")
[ -n "$PG_ROW" ] \
  && ok "row in ROLE_QUERY for query=$QUERY_ID role=$ROLE_ID" \
  || bad "no row in ROLE_QUERY — bind did not persist"

# ---------- 5. unbind ----------
hr
echo ">>> 5. DELETE /query/$QUERY_ID/role/$ROLE_ID"
UNBIND_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
  -X DELETE "$GATEWAY/api/sso-admin/query/$QUERY_ID/role/$ROLE_ID" "${AUTH[@]}")
assert_http 204 "$UNBIND_HTTP" "unbind role $ROLE_ID from query $QUERY_ID"

# ---------- 6. checked is now false ----------
hr
echo ">>> 6. GET /roles/checked after unbind — flag flips back"
CHECKED2=$(curl -sS "$GATEWAY/api/sso-admin/query/$QUERY_ID/roles/checked" "${AUTH[@]}")
MATCH2=$(echo "$CHECKED2" | python3 -c "
import sys, json
data = json.load(sys.stdin)
match = [r for r in data if str(r.get('roleId')) == '$ROLE_ID']
print('yes' if match and match[0].get('checked') is False else 'no')
")
[ "$MATCH2" = "yes" ] \
  && ok "role $ROLE_ID has checked=false after unbind" \
  || bad "role $ROLE_ID does NOT flip to checked=false after unbind"

PG_GONE=$(psql_q "SELECT 1 FROM ROLE_QUERY WHERE QUERY_ID=$QUERY_ID AND ROLE_ID=$ROLE_ID;")
[ -z "$PG_GONE" ] \
  && ok "ROLE_QUERY row removed" \
  || bad "ROLE_QUERY row still present after unbind"

# ---------- 7. verdict ----------
hr
echo ">>> 7. Verdict"
TOTAL=$((PASS + FAIL))
echo "    $PASS / $TOTAL checks passed"
if [ "$FAIL" -eq 0 ]; then
  echo "    ✅ PASS — QueryAdminService.RoleChecked contract matches frontend"
  exit 0
else
  echo "    ❌ FAIL — $FAIL check(s) failed. Inspect logs above."
  exit 1
fi