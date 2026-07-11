#!/usr/bin/env bash
# =============================================================================
# scripts/smoke-account-lifecycle.sh
#
# End-to-end smoke for the GET -> POST fix on /sso-admin/activateAccount
# and /sso-admin/restorePassword. The legacy shape took the new password
# in the URL query string, which leaked it via:
#
#   - server access logs (Tomcat / Spring)
#   - reverse-proxy access logs (ALB / nginx / GCP LB)
#   - browser history (full URL persisted)
#   - Referer header (any third-party analytics beacon, or any
#     subsequent navigation away from the activation page)
#   - CSRF: csrf.disable() at the controller layer plus
#     GET + permitAll meant an attacker could force-set the victim's
#     password with a single email-templated <img> tag, with no
#     victim interaction required.
#
# The fix moves the password into the JSON body and pins the token
# as the per-account single-use capability. The integration tests
# in sso-admin cover the controller shape; this script verifies the
# gateway + live-stack behaviour matches what a real caller sees.
#
# 6 checks:
#   1. Authenticated GET /sso-admin/activateAccount returns 405
#      (the path still matches a route predicate, but the controller
#      has only @PostMapping now, so Spring MVC's
#      RequestMappingHandlerMapping responds with Method Not Allowed
#      + an Allow: POST header). This is the live-stack pin that
#      closes the URL-leak surface — if anyone re-adds a
#      @GetMapping here, the smoke flips from green to red.
#   2. Authenticated GET /sso-admin/activateAccount?token=…&password=…
#      also returns 405 (the query-string shape is gone end-to-end;
#      not even an empty-body GET survives).
#   3. Authenticated GET /sso-admin/restorePassword returns 405.
#   4. Authenticated GET /sso-admin/restorePassword?token=…&password=…
#      also returns 405.
#   5. POST /sso-admin/activateAccount with password shorter than
#      6 characters returns 400 (Bean Validation @Size pin) — the
#      new surface still rejects weak passwords.
#   6. POST /sso-admin/activateAccount with empty body returns 400
#      (Spring MVC's @Valid failure on the TokenPasswordRequest).
#
# Run from project root (assumes the stack is up):
#   bash admin-ui/scripts/smoke-account-lifecycle.sh
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
echo ">>> Login (carries the Bearer token for the authenticated checks)"

LOGIN_HTTP=$(curl -sS -o /tmp/al-login-body.$$ -w '%{http_code}' \
  -X POST "$GATEWAY/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")
if [ "$LOGIN_HTTP" = "200" ]; then
  ok "Login returns 200"
else
  bad "Login expected 200, got $LOGIN_HTTP"
  cat /tmp/al-login-body.$$ || true
  exit 1
fi

ACCESS_JWT=$(python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" \
  < /tmp/al-login-body.$$)
rm -f /tmp/al-login-body.$$

# ---------- 1 + 2: GET /activateAccount ----------
hr
echo ">>> 1+2. GET /sso-admin/activateAccount (with and without query) -> 405"

GET_ACT_NOBODY=$(curl -sS -o /tmp/al-act-nobody.$$ -D /tmp/al-act-hdr.$$ \
  -w '%{http_code}' \
  -H "Authorization: Bearer $ACCESS_JWT" \
  "$GATEWAY/sso-admin/activateAccount")
GET_ACT_BODY=$(cat /tmp/al-act-nobody.$$ || true)

if [ "$GET_ACT_NOBODY" = "405" ]; then
  ok "Authenticated GET /sso-admin/activateAccount returns 405"
else
  bad "Authenticated GET /sso-admin/activateAccount expected 405, got $GET_ACT_NOBODY"
  echo "    body: $GET_ACT_BODY"
fi

# Spring's handler returns an Allow header listing the methods the
# path actually accepts; pinning that the header advertises POST
# is a defense-in-depth check that the 405 isn't coming from the
# gateway's 404-on-no-route-path.
if grep -qi '^allow:.*POST' /tmp/al-act-hdr.$$; then
  ok "Allow header advertises POST on the GET 405"
else
  bad "Allow header missing POST: $(grep -i '^allow' /tmp/al-act-hdr.$$ || echo '<none>')"
fi
rm -f /tmp/al-act-nobody.$$ /tmp/al-act-hdr.$$

# Now the same with the legacy query shape (token + password). If
# anyone re-adds a GET-with-query method, the password would end
# up in the URL again — this check pins that the shape is gone.
GET_ACT_QS=$(curl -sS -o /tmp/al-act-qs.$$ -w '%{http_code}' \
  -H "Authorization: Bearer $ACCESS_JWT" \
  "$GATEWAY/sso-admin/activateAccount?token=ANY_TOKEN&password=PWNED-via-URL")
if [ "$GET_ACT_QS" = "405" ]; then
  ok "Authenticated GET /sso-admin/activateAccount?token=…&password=… returns 405"
else
  bad "GET with query expected 405, got $GET_ACT_QS"
fi
rm -f /tmp/al-act-qs.$$

# ---------- 3 + 4: GET /restorePassword ----------
hr
echo ">>> 3+4. GET /sso-admin/restorePassword (with and without query) -> 405"

GET_RES_NOBODY=$(curl -sS -o /tmp/al-res-nobody.$$ -w '%{http_code}' \
  -H "Authorization: Bearer $ACCESS_JWT" \
  "$GATEWAY/sso-admin/restorePassword")
if [ "$GET_RES_NOBODY" = "405" ]; then
  ok "Authenticated GET /sso-admin/restorePassword returns 405"
else
  bad "Authenticated GET /sso-admin/restorePassword expected 405, got $GET_RES_NOBODY"
  echo "    body: $(cat /tmp/al-res-nobody.$$ || true)"
fi
rm -f /tmp/al-res-nobody.$$

GET_RES_QS=$(curl -sS -o /tmp/al-res-qs.$$ -w '%{http_code}' \
  -H "Authorization: Bearer $ACCESS_JWT" \
  "$GATEWAY/sso-admin/restorePassword?token=ANY_TOKEN&password=PWNED-via-URL")
if [ "$GET_RES_QS" = "405" ]; then
  ok "Authenticated GET /sso-admin/restorePassword?token=…&password=… returns 405"
else
  bad "GET restore with query expected 405, got $GET_RES_QS"
fi
rm -f /tmp/al-res-qs.$$

# ---------- 5 + 6: POST /activateAccount Bean Validation ----------
hr
echo ">>> 5+6. POST /sso-admin/activateAccount short-password + empty-body -> 400"

# Short password (3 chars) -> @Size(min=6) violation. We use a made-up
# token; the validation runs BEFORE the token lookup, so we get 400
# regardless of whether the token exists.
POST_SHORT=$(curl -sS -o /tmp/al-short.$$ -w '%{http_code}' \
  -X POST "$GATEWAY/sso-admin/activateAccount" \
  -H "Authorization: Bearer $ACCESS_JWT" \
  -H "Content-Type: application/json" \
  -d '{"token":"00000000-0000-0000-0000-000000000001","password":"123"}')
if [ "$POST_SHORT" = "400" ]; then
  ok "POST /activateAccount with password=123 returns 400 (@Size pin)"
else
  bad "POST with short password expected 400, got $POST_SHORT"
  echo "    body: $(cat /tmp/al-short.$$ || true)"
fi
rm -f /tmp/al-short.$$

# Missing fields entirely. POST without a body.
POST_EMPTY=$(curl -sS -o /tmp/al-empty.$$ -w '%{http_code}' \
  -X POST "$GATEWAY/sso-admin/activateAccount" \
  -H "Authorization: Bearer $ACCESS_JWT" \
  -H "Content-Type: application/json" \
  -d '{}')
if [ "$POST_EMPTY" = "400" ]; then
  ok "POST /activateAccount with empty body returns 400 (@Valid pin)"
else
  bad "POST with empty body expected 400, got $POST_EMPTY"
  echo "    body: $(cat /tmp/al-empty.$$ || true)"
fi
rm -f /tmp/al-empty.$$

# ---------- summary ----------
hr
TOTAL=$((PASS + FAIL))
echo "    $PASS / $TOTAL checks passed"
[ "$FAIL" -eq 0 ] || exit 1
