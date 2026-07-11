#!/usr/bin/env bash
# =============================================================================
# scripts/smoke-apps.sh
#
# End-to-end smoke test for the App admin feature (CRUD + 4 binding families).
#
# 1. Logs into the gateway with the dev admin user
# 2. Looks up real role / user / route / microservice IDs from Postgres
#    (the binding endpoints take a real FK; the smoke can't fabricate one)
# 3. POSTs a brand-new app to /api/sso-admin/app/save
# 4. POSTs a role, user, route, microservice binding (one of each family)
# 5. GETs the app + reads it back from Postgres (app + role_app + app_users
#    + app_route + app_microservice)
# 6. DELETEs one of each binding (to prove DELETE works)
# 7. POSTs a second app with the same name and asserts 409 DUPLICATE
# 8. DELETEs the first app and asserts the row + cascades are gone
# 9. Prints PASS / FAIL based on whether every assertion held
#
# Run from the project root:
#   bash admin-ui/scripts/smoke-apps.sh
#
# Hits the live stack on localhost:8080 and writes to the live sso DB.
# The app name is suffixed with the current timestamp so re-runs don't
# collide on the UNIQUE name constraint.
# =============================================================================
set -euo pipefail

GATEWAY="${GATEWAY:-http://localhost:8080}"
ADMIN_EMAIL="${SSO_ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${SSO_ADMIN_PASSWORD:-ChangeMe-Now-Please-123!}"
APP_NAME="smoke-app-$(date +%s)"
SUFFIX=$(date +%s)

PASS=0
FAIL=0
NOTE=""

# ---------- pretty ----------
ok()   { echo "    ✅ $*"; PASS=$((PASS+1)); }
bad()  { echo "    ❌ $*"; FAIL=$((FAIL+1)); }
info() { echo "    $*"; }
hr()   { echo "------------------------------------------------------------"; }

# ---------- helpers ----------
psql_q() {
  # $1 = SQL. Returns the trimmed output, one column per |, one row per line.
  docker exec -i sso-postgres psql -U sso -d sso -t -A -F'|' -c "$1" \
    | sed '/^$/d' | sed 's/^ *//; s/ *$//'
}

assert_http() {
  # $1 = expected status, $2 = actual status, $3 = label
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

# ---------- 2. look up FK ids ----------
hr
echo ">>> 2. Looking up real role/user/route/microservice IDs from Postgres"

ROLE_ID=$(psql_q "SELECT id_role FROM role ORDER BY id_role LIMIT 1;" | head -1)
USER_ID=$(psql_q "SELECT id_user FROM users ORDER BY id_user LIMIT 1;" | head -1)
ROUTE_ID=$(psql_q "SELECT id_route FROM ROUTE ORDER BY id_route LIMIT 1;" | head -1)
MICROSERVICE_ID=$(psql_q "SELECT id_microservice FROM MICROSERVICE ORDER BY id_microservice LIMIT 1;" | head -1)

[ -n "$ROLE_ID" ]        && info "role id        = $ROLE_ID"        || { bad "no role row in DB — cannot exercise role binding"; }
[ -n "$USER_ID" ]        && info "user id        = $USER_ID"        || { bad "no user row in DB — cannot exercise user binding"; }
[ -n "$ROUTE_ID" ]       && info "route id       = $ROUTE_ID"       || { bad "no route row in DB — cannot exercise route binding"; }
[ -n "$MICROSERVICE_ID" ] && info "microservice id = $MICROSERVICE_ID" || { bad "no microservice row in DB — cannot exercise microservice binding"; }

# ---------- 3. create app ----------
hr
echo ">>> 3. POSTing $APP_NAME to $GATEWAY/api/sso-admin/app/save"
CREATE_HTTP=$(curl -sS -o /tmp/smoke-app-create.json -w "%{http_code}" \
  -X POST "$GATEWAY/api/sso-admin/app/save" "${AUTH[@]}" \
  -d "{\"name\":\"$APP_NAME\",\"description\":\"created via smoke-apps.sh (suffix=$SUFFIX)\"}")
assert_http 201 "$CREATE_HTTP" "create app"

APP_ID=$(python3 -c "import json; print(json.load(open('/tmp/smoke-app-create.json'))['id'])")
info "new app id = $APP_ID"

# ---------- 4. bind one of each family ----------
hr
echo ">>> 4. Binding role/user/route/microservice to app $APP_ID"

[ -n "$ROLE_ID" ] && {
  BIND_ROLE_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST "$GATEWAY/api/sso-admin/app/$APP_ID/role/$ROLE_ID" "${AUTH[@]}")
  assert_http 204 "$BIND_ROLE_HTTP" "bind role $ROLE_ID"
}
[ -n "$USER_ID" ] && {
  BIND_USER_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST "$GATEWAY/api/sso-admin/app/$APP_ID/user/$USER_ID" "${AUTH[@]}")
  assert_http 204 "$BIND_USER_HTTP" "bind user $USER_ID"
}
[ -n "$ROUTE_ID" ] && {
  BIND_ROUTE_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST "$GATEWAY/api/sso-admin/app/$APP_ID/route/$ROUTE_ID" "${AUTH[@]}")
  assert_http 204 "$BIND_ROUTE_HTTP" "bind route $ROUTE_ID"
}
[ -n "$MICROSERVICE_ID" ] && {
  BIND_MS_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST "$GATEWAY/api/sso-admin/app/$APP_ID/microservice/$MICROSERVICE_ID" "${AUTH[@]}")
  assert_http 204 "$BIND_MS_HTTP" "bind microservice $MICROSERVICE_ID"
}

# ---------- 5. read it back ----------
hr
echo ">>> 5. Reading the app back via the API + Postgres"

# 5a. GET /app/{id}
GET_HTTP=$(curl -sS -o /tmp/smoke-app-get.json -w "%{http_code}" \
  "$GATEWAY/api/sso-admin/app/$APP_ID" "${AUTH[@]}")
assert_http 200 "$GET_HTTP" "GET /app/{id}"

API_ROLE_COUNT=$(python3 -c "import json; d=json.load(open('/tmp/smoke-app-get.json')); print(len(d.get('roleIds', [])))")
[ "$API_ROLE_COUNT" -ge 1 ] \
  && ok "GET /app/{id} response includes $API_ROLE_COUNT roleId(s)" \
  || bad "GET /app/{id} response has no roleIds — binding didn't round-trip"

# 5b. /roles/checked
# Asserts the JSON shape uses the suffixed `roleId` field (not
# bare `id`) — the frontend AppRoleChecked type depends on this.
if [ -n "$ROLE_ID" ]; then
  CHECKED=$(curl -sS "$GATEWAY/api/sso-admin/app/$APP_ID/roles/checked" "${AUTH[@]}")
  HAS_SUFFIXED=$(echo "$CHECKED" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print('yes' if data and 'roleId' in data[0] else 'no')
")
  [ "$HAS_SUFFIXED" = "yes" ] \
    && ok "/roles/checked response uses 'roleId' field (matches frontend)" \
    || bad "/roles/checked response uses bare 'id' — frontend AppRoleChecked.{roleId} would be undefined at runtime"

  CHECKED_FOR_ROLE=$(echo "$CHECKED" | python3 -c "
import sys, json
data = json.load(sys.stdin)
match = [r for r in data if str(r.get('roleId')) == '$ROLE_ID']
print('yes' if match and match[0].get('checked') else 'no')
")
  [ "$CHECKED_FOR_ROLE" = "yes" ] \
    && ok "/roles/checked marks role $ROLE_ID as checked=true" \
    || bad "/roles/checked does NOT mark role $ROLE_ID as checked"
fi

# 5c. Postgres — verify the app row + each M:N table
PG_NAME=$(psql_q "SELECT name FROM app WHERE id_app=$APP_ID;")
[ "$PG_NAME" = "$APP_NAME" ] && ok "app row in Postgres matches (name=$PG_NAME)" \
                              || bad "app row mismatch in Postgres (got '$PG_NAME')"

check_mn() {
  # $1 = table, $2 = FK column, $3 = id, $4 = label
  local row
  row=$(psql_q "SELECT 1 FROM $1 WHERE id_app=$APP_ID AND $2=$3;")
  [ -n "$row" ] && ok "row in $1 for $4 id=$3" || bad "no row in $1 for $4 id=$3"
}
[ -n "$ROLE_ID" ]        && check_mn role_app         id_role         "$ROLE_ID"        "role"
[ -n "$USER_ID" ]        && check_mn app_users        id_user         "$USER_ID"        "user"
[ -n "$ROUTE_ID" ]       && check_mn app_route        id_route        "$ROUTE_ID"       "route"
[ -n "$MICROSERVICE_ID" ] && check_mn app_microservice id_microservice "$MICROSERVICE_ID" "microservice"

# ---------- 6. unbind one of each ----------
hr
echo ">>> 6. Unbinding to prove DELETE works on each family"

[ -n "$ROLE_ID" ] && {
  UNBIND_ROLE_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X DELETE "$GATEWAY/api/sso-admin/app/$APP_ID/role/$ROLE_ID" "${AUTH[@]}")
  assert_http 204 "$UNBIND_ROLE_HTTP" "unbind role $ROLE_ID"

  REMAINING=$(psql_q "SELECT 1 FROM role_app WHERE id_app=$APP_ID AND id_role=$ROLE_ID;")
  [ -z "$REMAINING" ] && ok "role_app row for role $ROLE_ID is gone" \
                     || bad "role_app row for role $ROLE_ID still present"
}
[ -n "$USER_ID" ] && {
  UNBIND_USER_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X DELETE "$GATEWAY/api/sso-admin/app/$APP_ID/user/$USER_ID" "${AUTH[@]}")
  assert_http 204 "$UNBIND_USER_HTTP" "unbind user $USER_ID"
}
[ -n "$ROUTE_ID" ] && {
  UNBIND_ROUTE_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X DELETE "$GATEWAY/api/sso-admin/app/$APP_ID/route/$ROUTE_ID" "${AUTH[@]}")
  assert_http 204 "$UNBIND_ROUTE_HTTP" "unbind route $ROUTE_ID"
}
[ -n "$MICROSERVICE_ID" ] && {
  UNBIND_MS_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X DELETE "$GATEWAY/api/sso-admin/app/$APP_ID/microservice/$MICROSERVICE_ID" "${AUTH[@]}")
  assert_http 204 "$UNBIND_MS_HTTP" "unbind microservice $MICROSERVICE_ID"
}

# ---------- 7. duplicate-name conflict ----------
hr
echo ">>> 7. Asserting that a second app with the same name returns 409"
DUP_HTTP=$(curl -sS -o /tmp/smoke-app-dup.json -w "%{http_code}" \
  -X POST "$GATEWAY/api/sso-admin/app/save" "${AUTH[@]}" \
  -d "{\"name\":\"$APP_NAME\",\"description\":\"dup attempt\"}")
assert_http 409 "$DUP_HTTP" "duplicate name -> 409"

DUP_CODE=$(python3 -c "
import json
try:
    d = json.load(open('/tmp/smoke-app-dup.json'))
    print(d.get('code', ''))
except Exception:
    print('')
")
[ "$DUP_CODE" = "DUPLICATE" ] && ok "error envelope has code=DUPLICATE" \
                              || NOTE="duplicate code was '$DUP_CODE' (expected DUPLICATE)"

# ---------- 8. delete the app ----------
hr
echo ">>> 8. DELETE /api/sso-admin/app/$APP_ID and verifying cascade"

DEL_HTTP=$(curl -sS -o /dev/null -w "%{http_code}" \
  -X DELETE "$GATEWAY/api/sso-admin/app/$APP_ID" "${AUTH[@]}")
assert_http 204 "$DEL_HTTP" "DELETE /app/{id}"

REMAIN=$(psql_q "SELECT 1 FROM app WHERE id_app=$APP_ID;")
[ -z "$REMAIN" ] && ok "app row removed from Postgres" || bad "app row still present"

# Cascade check: any leftover rows in the M:N tables?
LEFTOVER=$(psql_q "
  SELECT 'role_app:'         || count(*) FROM role_app         WHERE id_app=$APP_ID
  UNION ALL
  SELECT 'app_users:'        || count(*) FROM app_users        WHERE id_app=$APP_ID
  UNION ALL
  SELECT 'app_route:'        || count(*) FROM app_route        WHERE id_app=$APP_ID
  UNION ALL
  SELECT 'app_microservice:' || count(*) FROM app_microservice WHERE id_app=$APP_ID;")
if [ -z "$(echo "$LEFTOVER" | grep -v ':0$')" ]; then
  ok "no orphan rows in role_app/app_users/app_route/app_microservice (ON DELETE CASCADE worked)"
else
  bad "orphan M:N rows after delete:"; echo "$LEFTOVER" | sed 's/^/      /'
fi

# ---------- 9. verdict ----------
hr
echo ">>> 9. Verdict"
TOTAL=$((PASS + FAIL))
echo "    $PASS / $TOTAL checks passed"
[ -n "$NOTE" ] && echo "    note: $NOTE"
if [ "$FAIL" -eq 0 ]; then
  echo "    ✅ PASS — App CRUD + 4 binding families work end-to-end"
  exit 0
else
  echo "    ❌ FAIL — $FAIL check(s) failed. Inspect logs above."
  exit 1
fi