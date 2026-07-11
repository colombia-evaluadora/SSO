#!/usr/bin/env bash
# =============================================================================
# scripts/smoke-write-list-table-columns.sh
#
# End-to-end smoke for the new GET /columns endpoint on
# query-service. The endpoint surfaces
# DatabaseMetaData.getColumns joined with getPrimaryKeys
# for the admin-ui Writes Catalog "pick column(s)" panel.
#
# Flow:
#  1. Login
#  2. GET /query-service-<instance>/columns?dialect=…&schema=…&table=…
#  3. Assert JSON envelope: List<ColumnInfo> with shape
#       {dialect, schema, table, name, dataType, nullable, primaryKey}
#  4. Assert at least 1 row
#  5. Assert every row's `schema` and `table` echo the input
#  6. Assert at least 1 row with primaryKey=true (table has a PK)
#       and at least 1 with primaryKey=false
#  7. Negative: unknown dialect → 400 + code "BAD_REQUEST"
#  8. Negative: malformed `table` (LIKE meta-char) → 400
#  9. PASS / FAIL
#
# Defaults assume the canonical dev setup:
#   - instance  = postgres  (compose-managed `sso-query-service-postgres`;
#                 the env var carries the SUFFIX only — the gateway
#                 auto-prepends `query-service-`, so passing the full
#                 service-id here would double the prefix and 404)
#   - dialect   = postgres
#   - schema    = public
#   - table     = app     (the SSO application table — has ID as PK
#                 and at least one non-PK column like NAME, so we
#                 exercise both halves of the primaryKey flag)
# Override any of these via the env before calling.
#
# Run from the project root:
#   bash admin-ui/scripts/smoke-write-list-table-columns.sh
# =============================================================================
set -euo pipefail

GATEWAY="${GATEWAY:-http://localhost:8080}"
ADMIN_EMAIL="${SSO_ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${SSO_ADMIN_PASSWORD:-ChangeMe-Now-Please-123!}"
INSTANCE="${QUERY_TABLES_TARGET:-postgres}"
DIALECT="${QUERY_TABLES_DIALECT:-postgres}"
SCHEMA_NAME="${QUERY_TABLE_COLUMNS_SCHEMA:-public}"
TABLE_NAME="${QUERY_TABLE_COLUMNS_TABLE:-app}"

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

# ---------- 2. GET /columns ----------
hr
echo ">>> 2. GET /query-service-$INSTANCE/columns?dialect=$DIALECT&schema=$SCHEMA_NAME&table=$TABLE_NAME"
LIST_HTTP=$(curl -sS -o /tmp/smoke-columns.json -w "%{http_code}" \
  "$GATEWAY/query-service-$INSTANCE/columns?dialect=$DIALECT&schema=$SCHEMA_NAME&table=$TABLE_NAME" "${AUTH[@]}")
assert_http 200 "$LIST_HTTP" "list columns for $SCHEMA_NAME.$TABLE_NAME on dialect=$DIALECT"

# ---------- 3. JSON shape ----------
hr
echo ">>> 3. JSON shape — every row has dialect/schema/table/name/dataType/nullable/primaryKey"

# 3a. Top-level array.
IS_ARRAY=$(python3 -c "
import json
data = json.load(open('/tmp/smoke-columns.json'))
print('yes' if isinstance(data, list) else 'no')
")
[ "$IS_ARRAY" = "yes" ] \
  && ok "response is a JSON array" \
  || bad "response is not a JSON array — admin-ui will throw on ColumnInfo.find lookup"

# 3b. At least 1 row.
COUNT=$(python3 -c "
import json
data = json.load(open('/tmp/smoke-columns.json'))
print(len(data) if isinstance(data, list) else 0)
")
if [ "$COUNT" -ge 1 ]; then
  ok "at least 1 column returned ($COUNT rows)"
else
  bad "expected ≥1 column — got $COUNT rows (table $SCHEMA_NAME.$TABLE_NAME should have at least ID + one more)"
fi

# 3c. Every row has the seven keys with no extras tolerated.
SHAPE_OK=$(python3 -c "
import json
data = json.load(open('/tmp/smoke-columns.json'))
required = {'dialect', 'schema', 'table', 'name', 'dataType', 'nullable', 'primaryKey'}
ok = all(isinstance(r, dict) and required.issubset(r.keys()) for r in data)
print('yes' if ok else 'no')
")
[ "$SHAPE_OK" = "yes" ] \
  && ok "every row has dialect + schema + table + name + dataType + nullable + primaryKey (matches ColumnInfo record)" \
  || bad "row shape mismatch — admin-ui ColumnInfo type will fail typecheck"

# 3d. schema + table fields echo the input.
ECHO_OK=$(python3 -c "
import json, sys
schema, table = sys.argv[1], sys.argv[2]
data = json.load(open('/tmp/smoke-columns.json'))
ok = all(r.get('schema') == schema and r.get('table') == table for r in data)
print('yes' if ok else 'no')
" "$SCHEMA_NAME" "$TABLE_NAME")
[ "$ECHO_OK" = "yes" ] \
  && ok "every row's schema+table echo the request (admin-ui uses them to disambiguate cross-schema columns)" \
  || bad "schema or table didn't echo on at least one row"

# 3e. dialect field echoes the requested key.
DIALECT_OK=$(python3 -c "
import json, sys
expected = sys.argv[1]
data = json.load(open('/tmp/smoke-columns.json'))
ok = all(r.get('dialect') == expected for r in data)
print('yes' if ok else 'no')
" "$DIALECT")
[ "$DIALECT_OK" = "yes" ] \
  && ok "every row's dialect=='${DIALECT}' (service lowercased correctly)" \
  || bad "dialect field on at least one row didn't match '${DIALECT}'"

# 3f. Spot-check: name is non-empty for every row.
NONEMPTY=$(python3 -c "
import json
data = json.load(open('/tmp/smoke-columns.json'))
ok = all((r.get('name') or '').strip() != '' for r in data)
print('yes' if ok else 'no')
")
[ "$NONEMPTY" = "yes" ] \
  && ok "every row has a non-empty column name" \
  || bad "at least one row has empty column name — getColumns() result is suspect"

# 3g. PrimaryKey bit exercises both halves — the test table has a PK AND
# at least one non-PK column, so this catches both "the flag is always
# false (broken join)" and "the flag is always true (mishandled)".
PK_BOTH=$(python3 -c "
import json
data = json.load(open('/tmp/smoke-columns.json'))
has_pk = any(r.get('primaryKey') is True for r in data)
has_non_pk = any(r.get('primaryKey') is False for r in data)
print('yes' if (has_pk and has_non_pk) else 'no')
")
[ "$PK_BOTH" = "yes" ] \
  && ok "primaryKey flag has both true and false rows on $SCHEMA_NAME.$TABLE_NAME (PK + non-PK columns present)" \
  || bad "primaryKey flag didn't have both true and false rows — getPrimaryKeys join or the flag is suspect"

# 3h. nullable field is a strict boolean on every row.
NULLABLE_BOOL=$(python3 -c "
import json
data = json.load(open('/tmp/smoke-columns.json'))
ok = all(isinstance(r.get('nullable'), bool) for r in data)
print('yes' if ok else 'no')
")
[ "$NULLABLE_BOOL" = "yes" ] \
  && ok "nullable is a strict boolean on every row (service normalizes YES/NO/true/false/empty/null)" \
  || bad "nullable is not a strict boolean on at least one row"

# ---------- 4. negative: unknown dialect ----------
hr
echo ">>> 4. negative — GET with unknown dialect should 400 BAD_REQUEST"
NEG_HTTP=$(curl -sS -o /tmp/smoke-columns-neg.json -w "%{http_code}" \
  "$GATEWAY/query-service-$INSTANCE/columns?dialect=does_not_exist_999&schema=$SCHEMA_NAME&table=$TABLE_NAME" "${AUTH[@]}")
assert_http 400 "$NEG_HTTP" "unknown dialect returns 400 (not 500)"
NEG_CODE=$(python3 -c "
import json
d = json.load(open('/tmp/smoke-columns-neg.json'))
print(d.get('code') if isinstance(d, dict) else 'no')
")
[ "$NEG_CODE" = "BAD_REQUEST" ] \
  && ok "400 envelope code='BAD_REQUEST' (matches query-service GlobalExceptionHandler)" \
  || bad "400 body didn't carry code='BAD_REQUEST' (got '${NEG_CODE}')"

# ---------- 5. negative: malformed `table` (LIKE meta-char) ----------
hr
echo ">>> 5. negative — GET with table='%' should 400 (no LIKE meta-chars allowed)"
LIKE_HTTP=$(curl -sS -o /tmp/smoke-columns-like.json -w "%{http_code}" \
  "$GATEWAY/query-service-$INSTANCE/columns?dialect=$DIALECT&schema=$SCHEMA_NAME&table=%25" "${AUTH[@]}")
assert_http 400 "$LIKE_HTTP" "malformed table '%' returns 400 (load guard)"
LIKE_CODE=$(python3 -c "
import json
d = json.load(open('/tmp/smoke-columns-like.json'))
print(d.get('code') if isinstance(d, dict) else 'no')
")
[ "$LIKE_CODE" = "BAD_REQUEST" ] \
  && ok "400 envelope code='BAD_REQUEST' for malformed table" \
  || bad "malformed-table 400 body didn't carry code='BAD_REQUEST' (got '${LIKE_CODE}')"

# ---------- 6. negative: missing `table` ----------
hr
echo ">>> 6. negative — GET with missing 'table' should 400 BAD_REQUEST"
MISSING_HTTP=$(curl -sS -o /tmp/smoke-columns-missing.json -w "%{http_code}" \
  "$GATEWAY/query-service-$INSTANCE/columns?dialect=$DIALECT&schema=$SCHEMA_NAME" "${AUTH[@]}")
assert_http 400 "$MISSING_HTTP" "missing table param returns 400"

# ---------- 7. verdict ----------
hr
echo ">>> 7. Verdict"
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "    $PASS / $TOTAL checks passed"
  echo "    ✅ PASS — ColumnsController contract matches admin-ui ColumnInfo"
  exit 0
else
  echo "    $PASS / $TOTAL checks passed"
  echo "    ❌ FAIL — $FAIL check(s) failed"
  exit 1
fi
