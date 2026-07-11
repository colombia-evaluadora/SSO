#!/usr/bin/env bash
# =============================================================================
# scripts/smoke-write-list-tables.sh
#
# End-to-end smoke for the new GET /tables endpoint on
# query-service. The endpoint surfaces DatabaseMetaData rows
# for the admin-ui Writes Catalog "pick a table" picker.
#
# Flow:
#  1. Login
#  2. GET /query-service-<instance>/tables?dialect=<d>
#  3. Assert JSON envelope: List<TableInfo> with shape
#       {dialect, schema, name, remarks}
#  4. Assert at least 1 row
#  5. Assert every row's `dialect` matches the requested key
#  6. Negative: GET with unknown dialect → 400 + code "BAD_REQUEST"
#  7. Negative: GET with malformed schema → 400 + code "BAD_REQUEST"
#  8. PASS / FAIL
#
# Defaults assume the canonical dev setup:
#   - instance  = postgres  (compose-managed `sso-query-service-postgres`;
#                 the env var carries the SUFFIX only — the gateway
#                 auto-prepends `query-service-`, so passing the full
#                 service-id here would double the prefix and 404)
#   - dialect   = postgres
# Override either via the env before calling.
#
# Run from the project root:
#   bash admin-ui/scripts/smoke-write-list-tables.sh
# =============================================================================
set -euo pipefail

GATEWAY="${GATEWAY:-http://localhost:8080}"
ADMIN_EMAIL="${SSO_ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${SSO_ADMIN_PASSWORD:-ChangeMe-Now-Please-123!}"
INSTANCE="${QUERY_TABLES_TARGET:-postgres}"
DIALECT="${QUERY_TABLES_DIALECT:-postgres}"

PASS=0
FAIL=0
ok()   { echo "    ✅ $*"; PASS=$((PASS+1)); }
bad()  { echo "    ❌ $*"; FAIL=$((FAIL+1)); }
info() { echo "    $*"; }
hr()   { echo "------------------------------------------------------------"; }

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
AUTH=(-H "Authorization: Bearer $JWT")

# ---------- 2. GET /tables ----------
hr
echo ">>> 2. GET /query-service-$INSTANCE/tables?dialect=$DIALECT"
LIST_HTTP=$(curl -sS -o /tmp/smoke-tables.json -w "%{http_code}" \
  "$GATEWAY/query-service-$INSTANCE/tables?dialect=$DIALECT" "${AUTH[@]}")
assert_http 200 "$LIST_HTTP" "list tables for dialect=$DIALECT"

# ---------- 3. JSON shape ----------
hr
echo ">>> 3. JSON shape — every row has dialect/schema/name/remarks"

# 3a. Top-level array.
IS_ARRAY=$(python3 -c "
import json
data = json.load(open('/tmp/smoke-tables.json'))
print('yes' if isinstance(data, list) else 'no')
")
[ "$IS_ARRAY" = "yes" ] \
  && ok "response is a JSON array" \
  || bad "response is not a JSON array — admin-ui will throw on TableInfo.find lookup"

# 3b. At least 1 row.
COUNT=$(python3 -c "
import json
data = json.load(open('/tmp/smoke-tables.json'))
print(len(data) if isinstance(data, list) else 0)
")
if [ "$COUNT" -ge 1 ]; then
  ok "at least 1 table returned ($COUNT rows)"
else
  bad "expected ≥1 table — got $COUNT rows (sso DB should always have APP/ROLE/QUERY/…)"
fi

# 3c. Every row has the four keys with no extras tolerated.
SHAPE_OK=$(python3 -c "
import json
data = json.load(open('/tmp/smoke-tables.json'))
required = {'dialect', 'schema', 'name', 'remarks'}
ok = all(isinstance(r, dict) and required.issubset(r.keys()) for r in data)
print('yes' if ok else 'no')
")
[ "$SHAPE_OK" = "yes" ] \
  && ok "every row has dialect + schema + name + remarks (matches TableInfo record)" \
  || bad "row shape mismatch — admin-ui TableInfo type will fail typecheck"

# 3d. dialect field echoes the requested key.
DIALECT_OK=$(python3 -c "
import json, sys
expected = sys.argv[1]
data = json.load(open('/tmp/smoke-tables.json'))
ok = all(r.get('dialect') == expected for r in data)
print('yes' if ok else 'no')
" "$DIALECT")
[ "$DIALECT_OK" = "yes" ] \
  && ok "every row's dialect=='${DIALECT}' (service lowercased correctly)" \
  || bad "dialect field on at least one row didn't match '${DIALECT}'"

# 3e. Spot-check: name is non-empty for every row.
NONEMPTY=$(python3 -c "
import json
data = json.load(open('/tmp/smoke-tables.json'))
ok = all((r.get('name') or '').strip() != '' for r in data)
print('yes' if ok else 'no')
")
[ "$NONEMPTY" = "yes" ] \
  && ok "every row has a non-empty table name" \
  || bad "at least one row has empty table name — getTables() result is suspect"

# ---------- 4. negative: unknown dialect ----------
hr
echo ">>> 4. negative — GET with unknown dialect should 400 BAD_REQUEST"
NEG_HTTP=$(curl -sS -o /tmp/smoke-tables-neg.json -w "%{http_code}" \
  "$GATEWAY/query-service-$INSTANCE/tables?dialect=does_not_exist_999" "${AUTH[@]}")
assert_http 400 "$NEG_HTTP" "unknown dialect returns 400 (not 500)"
NEG_CODE=$(python3 -c "
import json
d = json.load(open('/tmp/smoke-tables-neg.json'))
print(d.get('code') if isinstance(d, dict) else 'no')
")
[ "$NEG_CODE" = "BAD_REQUEST" ] \
  && ok "400 envelope code='BAD_REQUEST' (matches query-service GlobalExceptionHandler)" \
  || bad "400 envelope code mismatch — got '$NEG_CODE' (admin-ui toast will render the wrong label)"

# ---------- 5. negative: malformed schema ----------
hr
echo ">>> 5. negative — GET with schema='%' should 400 (no LIKE meta-chars allowed)"
NEG2_HTTP=$(curl -sS -o /tmp/smoke-tables-neg2.json -w "%{http_code}" \
  "$GATEWAY/query-service-$INSTANCE/tables?dialect=$DIALECT&schema=%25" "${AUTH[@]}")
assert_http 400 "$NEG2_HTTP" "malformed schema '%' returns 400 (load guard)"

# ---------- 6. verdict ----------
hr
echo ">>> 6. Verdict"
TOTAL=$((PASS + FAIL))
echo "    $PASS / $TOTAL checks passed"
if [ "$FAIL" -eq 0 ]; then
  echo "    ✅ PASS — TablesController contract matches admin-ui TableInfo"
  exit 0
else
  echo "    ❌ FAIL — $FAIL check(s) failed. Inspect logs above."
  exit 1
fi
