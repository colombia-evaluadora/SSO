#!/usr/bin/env bash
# =============================================================================
# scripts/smoke-myMenu.sh
#
# Pins the dynamic sidebar contract at the live-stack layer.
# The SPA's Sidebar.tsx renders GET /sso-admin/myMenu
# (after commits 0f5b03d + da92221 + 62a0470 + 22aa6ef +
# d7e7412 landed). The backend's MyMenuService.forCaller()
# filters routes per caller via
# RouteRepository.findVisibleForRoles(roleIds). For the
# menu to render anything, the seed data in
# postgres/init/08-seed-sso-admin-routes.sh AND
# 09-seed-sso-admin-app.sh MUST have run (one seeds the
# direct ROLE_ROUTE branch; the other seeds the App-grant
# branch).
#
# 10 checks:
#   1. /myMenu returns 200 for a logged-in admin.
#   2. /myMenu returns >= 12 routes (the twelve the SPA
#      expects to see, per the seed scripts).
#   3. Each of the twelve expected paths appears in the
#      response (catches a deleted seed row).
#   4. The Spanish legacy labels appear (matches the
#      fallback name-keyword icon map in
#      Sidebar.tsx resolveIcon — confirms the rendered
#      icons will resolve before any admin populates the
#      icon column manually).
#   5. The SSO-ADMIN App exists AND is bound to ADMIN via
#      role_app (pin on the App-grant branch of the
#      findVisibleForRoles union).
#   6. The SSO-ADMIN App has >= 11 routes linked via
#      app_route — 11, not 12: /admin/writes was
#      deliberately unbound from SSO-ADMIN via
#      AppService.unbindRoute (DELETE
#      /app/{id}/route/{routeId}, the App edit page's
#      route picker) and stays unbound. It's still
#      visible in the UNSCOPED /myMenu (checks 2-4) via
#      its direct role_route binding — unbinding from an
#      app doesn't revoke a separate fine-grained grant.
#      app_route (App.routes, the M:N AppService.bindRoute/
#      unbindRoute mutate) is the sole app-membership
#      relationship for a route — ROUTE has no "primary
#      app" FK of its own.
#   7. /myMenu?app=SSO-ADMIN returns >= 11 routes and
#      EXCLUDES /admin/writes — pins the app-scoped
#      overload of RouteRepository.findVisibleForRoles(
#      roleIds, appId), which reads app_route. Confirms
#      the fix for: unbinding a route from an app via the
#      app_route "checked" list must actually remove it
#      from that app's scoped menu. SSO-ADMIN is the
#      canonical name seeded by 09-seed-sso-admin-app.sh.
#   8. /myMenu?app=Nonexistent returns 200 + 0 routes —
#      pins the "unknown app -> 200 + []" contract from
#      MyMenuService.forCaller(auth, appName). Catches
#      a regression where someone might short-circuit
#      unknown names to a 404 (which would break the
#      SPA's render path).
#   9. /myMenu?app= (blank) returns 200 + 0 routes —
#      the controller's trim() normalizes blank to "no
#      filter" semantics; this check pins that a
#      literal empty value is handled the same as null
#      instead of being passed through to the DB layer
#      with bogus semantics.
#  10. /myMenu without ?app= still returns the full
#      union (>= 12 routes for ADMIN) — pins the
#      backwards-compat path so legacy clients (smoke
#      scripts, multi-tenant menu editors) keep
#      getting the same answer they always did.
#
# Negative path (NOT covered here): a non-admin user
# with role bindings sees only the bound subset. That's a
# separate smoke once we can provision a non-admin test
# user in CI without coupling to djromer's password.
#
# Run from project root (assumes the stack is up):
#   bash admin-ui/scripts/smoke-myMenu.sh
# =============================================================================
set -euo pipefail

GATEWAY="${GATEWAY:-http://localhost:8080}"
ADMIN_EMAIL="${SSO_ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${SSO_ADMIN_PASSWORD:-ChangeMe-Now-Please-123!}"

PASS=0
FAIL=0
ok()  { echo "    ✅ $*"; PASS=$((PASS+1)); }
bad() { echo "    ❌ $*"; FAIL=$((FAIL+1)); }
info(){ echo "    $*"; }
hr()  { echo "------------------------------------------------------------"; }

# ---------- login ----------
hr
echo ">>> Login (admin)"

LOGIN_HTTP=$(curl -sS -o /tmp/mymenu-login-body.$$ -w '%{http_code}' \
  -X POST "$GATEWAY/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")
if [ "$LOGIN_HTTP" = "200" ]; then
  ok "Login returns 200"
else
  bad "Login expected 200, got $LOGIN_HTTP"
  cat /tmp/mymenu-login-body.$$ || true
  exit 1
fi

ACCESS_JWT=$(python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" \
  < /tmp/mymenu-login-body.$$)
rm -f /tmp/mymenu-login-body.$$

# ---------- 1. /myMenu returns 200 ----------
hr
echo ">>> 1. GET /sso-admin/myMenu returns 200"

GET_HTTP=$(curl -sS -o /tmp/mymenu-body.$$ -w '%{http_code}' \
  -H "Authorization: Bearer $ACCESS_JWT" \
  "$GATEWAY/sso-admin/myMenu")
if [ "$GET_HTTP" = "200" ]; then
  ok "/myMenu returns 200"
else
  bad "/myMenu expected 200, got $GET_HTTP"
  cat /tmp/mymenu-body.$$ || true
  exit 1
fi

# ---------- 2. /myMenu returns >= 12 routes ----------
hr
echo ">>> 2. /myMenu body has >= 12 entries"

ROUTE_COUNT=$(python3 -c "import json; print(len(json.load(open('/tmp/mymenu-body.$$'))))")
if [ "$ROUTE_COUNT" -ge 12 ]; then
  ok "Body has $ROUTE_COUNT routes (>= 12)"
else
  bad "Expected >= 12 routes, got $ROUTE_COUNT"
  cat /tmp/mymenu-body.$$ || true
fi

# ---------- 3. each of the 12 expected paths is present ----------
hr
echo ">>> 3. All twelve expected routes present in /myMenu"

EXPECTED_PATHS=(
  "/admin/users"
  "/admin/roles"
  "/admin/groups"
  "/admin/microservices"
  "/admin/query-services"
  "/admin/queries"
  "/admin/query-catalog"
  "/admin/dynamic-crud"
  "/admin/endpoints"
  "/admin/routes"
  "/admin/apps"
  "/admin/writes"
)
BODY=$(cat /tmp/mymenu-body.$$)
for path in "${EXPECTED_PATHS[@]}"; do
  if echo "$BODY" | grep -q "\"$path\""; then
    ok "$path is in the response"
  else
    bad "$path is MISSING from /myMenu response"
  fi
done

# ---------- 4. the legacy Spanish labels render ----------
hr
echo ">>> 4. Each label is in Spanish (matches legacy sidebar copy)"

EXPECTED_LABELS=(
  "Usuarios"
  "Roles"
  "Grupos"
  "Microservicios"
  "Query Services"
  "Queries Catalog"
  "Queries (admin)"
  "Dynamic CRUD"
  "Endpoints"
  "Rutas"
  "Apps"
  "Writes"
)
for label in "${EXPECTED_LABELS[@]}"; do
  if echo "$BODY" | grep -q "\"$label\""; then
    ok "label '$label' is in the response"
  else
    bad "label '$label' is MISSING from /myMenu response"
  fi
done

rm -f /tmp/mymenu-body.$$

# ---------- 5. SSO-ADMIN app bound to ADMIN role ----------
hr
echo ">>> 5. SSO-ADMIN App exists AND is bound to ADMIN role"

PSQL="docker exec -e PGPASSWORD=${POSTGRES_PASSWORD:-change-me-in-prod} sso-postgres psql -U ${POSTGRES_USER:-sso} -d ${POSTGRES_DB:-sso} -At -c"

# 5a. SSO-ADMIN app row exists.
APP_ROW=$($PSQL "SELECT id_app || '|' || (SELECT count(*) FROM app WHERE name='SSO-ADMIN') FROM app WHERE name='SSO-ADMIN'" 2>/dev/null)
if [ -n "$APP_ROW" ] && echo "$APP_ROW" | grep -q '|1$'; then
  ok "SSO-ADMIN App row exists in app table"
else
  bad "SSO-ADMIN App row missing from app table — did 09-seed-sso-admin-app.sh run?"
fi

# 5b. role_app has ADMIN -> SSO-ADMIN binding.
ROLE_APP_COUNT=$($PSQL "SELECT count(*) FROM role_app ra JOIN app a ON a.id_app = ra.id_app JOIN role r ON r.id_role = ra.id_role WHERE a.name='SSO-ADMIN' AND r.name='ADMIN'" 2>/dev/null)
if [ "$ROLE_APP_COUNT" = "1" ]; then
  ok "role_app has ADMIN -> SSO-ADMIN binding"
else
  bad "role_app missing ADMIN -> SSO-ADMIN binding (count=$ROLE_APP_COUNT)"
fi

# ---------- 6. SSO-ADMIN app has >= 11 routes linked ----------
hr
echo ">>> 6. SSO-ADMIN App links >= 11 routes via app_route"

APP_ROUTE_COUNT=$($PSQL "SELECT count(*) FROM app_route ar JOIN app a ON a.id_app = ar.id_app WHERE a.name='SSO-ADMIN'" 2>/dev/null)
if [ "$APP_ROUTE_COUNT" -ge 11 ] 2>/dev/null; then
  ok "app_route has $APP_ROUTE_COUNT SSO-ADMIN links (>= 11)"
else
  bad "app_route has $APP_ROUTE_COUNT SSO-ADMIN links (expected >= 11)"
fi

# No ROUTE.id_app assertion here — that column was removed
# from ROUTE entirely; app_route (asserted above) is the only
# app-membership relationship a route has.

# ---------- 7. ?app=SSO-ADMIN returns >= 11 routes ----------
hr
echo ">>> 7. GET /sso-admin/myMenu?app=SSO-ADMIN returns >= 11 routes"

APP_HTTP=$(curl -sS -o /tmp/mymenu-app-body.$$ -w '%{http_code}' \
  -H "Authorization: Bearer $ACCESS_JWT" \
  "$GATEWAY/sso-admin/myMenu?app=SSO-ADMIN")
if [ "$APP_HTTP" = "200" ]; then
  ok "?app=SSO-ADMIN returns 200"
else
  bad "?app=SSO-ADMIN expected 200, got $APP_HTTP"
  cat /tmp/mymenu-app-body.$$ || true
fi

APP_COUNT=$(python3 -c "import json; print(len(json.load(open('/tmp/mymenu-app-body.$$'))))")
if [ "$APP_COUNT" -ge 11 ]; then
  ok "?app=SSO-ADMIN body has $APP_COUNT routes (>= 11)"
else
  bad "?app=SSO-ADMIN expected >= 11 routes, got $APP_COUNT"
  cat /tmp/mymenu-app-body.$$ || true
fi

APP_BODY=$(cat /tmp/mymenu-app-body.$$)

# Pin one specific path as a regression catch — /admin/users
# is bound (via app_route) to a different app (not SSO-ADMIN),
# so it MUST NOT appear when the SPA scope is SSO-ADMIN. If it
# does, the app_route filter on the broad branch regressed.
if echo "$APP_BODY" | grep -q '"/admin/users"'; then
  bad "?app=SSO-ADMIN leaks /admin/users (bound to a different app via app_route — broad-branch filter regressed)"
else
  ok "?app=SSO-ADMIN correctly excludes /admin/users (bound to a different app via app_route)"
fi

# Pin the specific bug this session fixed — /admin/writes was
# deliberately unbound from SSO-ADMIN via app_route (the App
# edit page's route picker / AppService.unbindRoute). ROUTE
# used to also have its own id_app FK (separate from app_route,
# untouched by unbindRoute), which findVisibleForRoles filtered
# on instead — so an unbound route kept leaking into the scoped
# menu. That FK has since been removed from ROUTE entirely;
# app_route is now the only relationship. If this check ever
# fails again, something reintroduced a route<->app pointer
# that bypasses app_route.
if echo "$APP_BODY" | grep -q '"/admin/writes"'; then
  bad "?app=SSO-ADMIN leaks /admin/writes (unbound from SSO-ADMIN via app_route — filter regressed to bypassing app_route)"
else
  ok "?app=SSO-ADMIN correctly excludes /admin/writes (unbound via app_route)"
fi
rm -f /tmp/mymenu-app-body.$$

# ---------- 8. ?app=Nonexistent returns 0 routes ----------
hr
echo ">>> 8. GET /sso-admin/myMenu?app=Nonexistent returns 0 routes"

UNK_HTTP=$(curl -sS -o /tmp/mymenu-unk-body.$$ -w '%{http_code}' \
  -H "Authorization: Bearer $ACCESS_JWT" \
  "$GATEWAY/sso-admin/myMenu?app=Nonexistent")
if [ "$UNK_HTTP" = "200" ]; then
  ok "?app=Nonexistent returns 200 (not 404)"
else
  bad "?app=Nonexistent expected 200, got $UNK_HTTP"
  cat /tmp/mymenu-unk-body.$$ || true
fi

UNK_COUNT=$(python3 -c "import json; print(len(json.load(open('/tmp/mymenu-unk-body.$$'))))")
if [ "$UNK_COUNT" = "0" ]; then
  ok "?app=Nonexistent body has 0 routes (200 + [])"
else
  bad "?app=Nonexistent expected 0 routes, got $UNK_COUNT"
  cat /tmp/mymenu-unk-body.$$ || true
fi
rm -f /tmp/mymenu-unk-body.$$

# ---------- 9. /myMenu (no ?app=) still returns the full union ----------
hr
echo ">>> 9. GET /sso-admin/myMenu (no ?app=) returns the full union (back-compat)"

# This is the same call as check #2 but re-issued with the
# no-query-string shape (not URL-encoded) so a future
# regression that forces `?app=` somewhere in the middleware
# chain shows up here even if the JSON body still parses.
NC_HTTP=$(curl -sS -o /tmp/mymenu-nc-body.$$ -w '%{http_code}' \
  -H "Authorization: Bearer $ACCESS_JWT" \
  "$GATEWAY/sso-admin/myMenu")
if [ "$NC_HTTP" = "200" ]; then
  ok "no-?app= returns 200"
else
  bad "no-?app= expected 200, got $NC_HTTP"
fi

NC_COUNT=$(python3 -c "import json; print(len(json.load(open('/tmp/mymenu-nc-body.$$'))))")
if [ "$NC_COUNT" -ge 12 ]; then
  ok "no-?app= body has $NC_COUNT routes (>= 12; back-compat preserved)"
else
  bad "no-?app= expected >= 12 routes (union), got $NC_COUNT"
fi
rm -f /tmp/mymenu-nc-body.$$

# ---------- 10. ?app= (blank) is treated as no filter ----------
hr
echo ">>> 10. GET /sso-admin/myMenu?app= (blank) returns the full union (same as no param)"

# Empty-value query params (?app=) are degenerate; the
# controller's trim() collapses "" + null into the same
# branch which falls through to MyMenuService.forCaller(auth)
# (the 1-arg overload) — i.e. the full union, not the scoped
# one. This matches the documented contract "blank ?app= is
# treated the same as omitted; some HTTP clients send
# ?app=&foo=bar and we want to ignore them" from the plan.
# The earlier check #8 (?app=Nonexistent) already pins the
# LEGITIMATELY-unknown-name path (200 + []); this check pins
# the BLANK fallback to the no-filter union instead.
#
# Run AFTER check #9 so NC_COUNT is defined for the
# equality assertion below (the script uses `set -u` which
# rejects unbound variable references).
BLANK_HTTP=$(curl -sS -o /tmp/mymenu-blank-body.$$ -w '%{http_code}' \
  -H "Authorization: Bearer $ACCESS_JWT" \
  "$GATEWAY/sso-admin/myMenu?app=")
if [ "$BLANK_HTTP" = "200" ]; then
  ok "?app= (blank) returns 200"
else
  bad "?app= (blank) expected 200, got $BLANK_HTTP"
fi

BLANK_COUNT=$(python3 -c "import json; print(len(json.load(open('/tmp/mymenu-blank-body.$$'))))")
if [ "$BLANK_COUNT" -ge 12 ]; then
  ok "?app= (blank) body has $BLANK_COUNT routes (>= 12; collapsed to no-filter union)"
else
  bad "?app= (blank) expected >= 12 routes (no-filter union), got $BLANK_COUNT"
fi

# Regression catch — blank must return the SAME count as
# the explicit no-param call. If a future change accidentally
# sends blank into the scoped branch, BLANK_COUNT would jump
# to 12 (different from no-param's 13) and this comparison
# fails.
if [ "$BLANK_COUNT" = "$NC_COUNT" ]; then
  ok "?app= (blank) count matches no-?app= count ($BLANK_COUNT == $NC_COUNT)"
else
  bad "?app= (blank) count ($BLANK_COUNT) differs from no-?app= count ($NC_COUNT) — blank is not collapsed to no-filter"
fi
rm -f /tmp/mymenu-blank-body.$$

# ---------- summary ----------
hr
TOTAL=$((PASS + FAIL))
echo "    $PASS / $TOTAL checks passed"
[ "$FAIL" -eq 0 ] || exit 1
