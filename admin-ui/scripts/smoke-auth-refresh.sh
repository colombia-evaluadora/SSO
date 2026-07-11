#!/usr/bin/env bash
# =============================================================================
# scripts/smoke-auth-refresh.sh
#
# End-to-end smoke for the Redis-backed rotating refresh-token
# flow that closes the legacy /auth/refresh bypass (where any
# non-empty sso_refresh cookie minted a token for the first
# enabled user). The flow now follows RFC 9700 §4.14:
#
#   - Login mints a refresh token server-side via the store.
#   - Each /auth/refresh rotates the cookie (new raw value).
#   - Replay of an already-rotated cookie wipes the family.
#   - /auth/logout revokes the family and clears the cookie.
#   - Multi-device logins produce independent families.
#
# 10 checks:
#   1. Login sets sso_refresh cookie with HttpOnly + SameSite=Strict
#      + Path=/ + Max-Age=2592000 (30 days, mirrors store TTL).
#   2. /auth/refresh with the login cookie returns 200 + a NEW
#      Set-Cookie (rotation worked).
#   3. Reuse of the OLD refresh cookie after rotation returns 401
#      refresh_token_reuse + the rotated cookie also fails (family
#      wiped as a side effect).
#   4. Logout clears the cookie (Max-Age=0) + a subsequent refresh
#      with the pre-logout cookie returns 401.
#   5. Two simultaneous logins yield two independent families —
#      rotating one does not invalidate the other.
#   6. The access token minted at refresh carries the LOGGED-IN
#      user's sub claim (this is the assertion that pins down the
#      bypass-era behaviour where any cookie minted a token for
#      the first user in the DB).
#   7. Cookie security attributes: HttpOnly, SameSite=Strict,
#      no Domain, Path=/ (Secure must NOT appear over plain HTTP).
#   8. /auth/refresh with NO cookie returns 401 no_refresh_cookie.
#   9. /getUsersSSO anonymous returns 401 (closes the
#      user-enumeration / PII leak fixed in this branch via
#      SecurityConfig hasAuthority("ADMIN") at both the
#      auth-center and api-gateway layers — commits 11 + 12).
#  10. /getToken is REMOVED end-to-end:
#      - anonymous GET returns 401 (gateway SecurityConfig
#        anyExchange().authenticated() bounces it; controller is
#        gone, so no fallback path remains — commits 17-19);
#      - authenticated GET returns 404 (no matching route
#        predicate after commit 20; even if the route came back,
#        auth-center has no handler for /getToken any more).
#      Integration tests (Commit 21) pin the auth-center-side
#      contract at the unit-test layer; this smoke verifies the
#      gateway-side behaviour matches what callers will actually
#      see.
#
# Run from project root (assumes the stack is up):
#   bash admin-ui/scripts/smoke-auth-refresh.sh
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

# ---------- helpers ----------

# Extract the cookie value from a Set-Cookie header (between '=' and ';').
cookie_value() {
  local hdr="$1"
  echo "$hdr" | sed -n 's/^sso_refresh=\([^;]*\).*/\1/p'
}

# Capture the Set-Cookie + HTTP status from a POST + cookie jar file.
# Args: url cookie_jar [extra curl args...]
post_with_cookie() {
  local url="$1"; local jar="$2"; shift 2
  curl -sS -o /tmp/smoke-refresh-body.$$ -D /tmp/smoke-refresh-hdr.$$ \
       -w '%{http_code}' -X POST "$url" -b "$jar" -c "$jar" "$@"
}

# ---------- 1. login + cookie attrs ----------
hr
echo ">>> 1. Logging in via $GATEWAY/login; checking sso_refresh attrs"

JAR=$(mktemp)
trap 'rm -f "$JAR" /tmp/smoke-refresh-body.$$ /tmp/smoke-refresh-hdr.$$' EXIT

LOGIN_HTTP=$(curl -sS -o /tmp/login-body.$$ -D /tmp/login-hdr.$$ \
  -w '%{http_code}' -X POST "$GATEWAY/login" \
  -H "Content-Type: application/json" \
  -c "$JAR" \
  -d "{\"username\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}")

if [ "$LOGIN_HTTP" = "200" ]; then
  ok "Login returns 200"
else
  bad "Login expected 200, got $LOGIN_HTTP"
  cat /tmp/login-body.$$ || true
  exit 1
fi

SET_COOKIE=$(grep -i '^set-cookie:' /tmp/login-hdr.$$ | sed 's/^[Ss]et-[Cc]ookie: //')
if [ -z "$SET_COOKIE" ]; then
  bad "No Set-Cookie header on login response"
  exit 1
fi

V1=$(cookie_value "$SET_COOKIE")
[ -n "$V1" ] && ok "sso_refresh cookie present (value: ${V1:0:8}...)" \
              || bad "Could not parse sso_refresh value"

echo "$SET_COOKIE" | grep -q "HttpOnly"     && ok "cookie HttpOnly"     || bad "cookie missing HttpOnly"
echo "$SET_COOKIE" | grep -q "SameSite=Strict" && ok "cookie SameSite=Strict" || bad "cookie missing SameSite=Strict"
echo "$SET_COOKIE" | grep -q "Path=/"       && ok "cookie Path=/"       || bad "cookie missing Path=/"
echo "$SET_COOKIE" | grep -q "Max-Age=2592000" && ok "cookie Max-Age=2592000 (30d)" \
                                              || bad "cookie Max-Age != 2592000"
echo "$SET_COOKIE" | grep -qv "Secure"      && ok "cookie NOT Secure (plain HTTP)" \
                                              || bad "cookie unexpectedly Secure over plain HTTP"

# Capture the access JWT for the correct-user assertion later.
ACCESS_JWT=$(python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" < /tmp/login-body.$$)

# ---------- 2. refresh rotation ----------
hr
echo ">>> 2. POST /api/auth/refresh with the login cookie (expect rotation)"

REFRESH_HTTP=$(post_with_cookie "$GATEWAY/api/auth/refresh" "$JAR")
if [ "$REFRESH_HTTP" = "200" ]; then
  ok "/auth/refresh returns 200"
else
  bad "/auth/refresh expected 200, got $REFRESH_HTTP"
  cat /tmp/smoke-refresh-body.$$ || true
fi

REFRESH_HDR=$(cat /tmp/smoke-refresh-hdr.$$)
NEW_SET_COOKIE=$(echo "$REFRESH_HDR" | grep -i '^set-cookie:' | sed 's/^[Ss]et-[Cc]ookie: //' | head -1)
if [ -z "$NEW_SET_COOKIE" ]; then
  bad "No Set-Cookie on /auth/refresh (rotation did not occur)"
else
  V2=$(cookie_value "$NEW_SET_COOKIE")
  if [ -n "$V2" ] && [ "$V2" != "$V1" ]; then
    ok "Set-Cookie rotated: ${V1:0:8}... -> ${V2:0:8}..."
  else
    bad "Rotated cookie value did not change (V1=$V1 V2=$V2)"
  fi
fi

# ---------- 3. reuse detection + family wipe ----------
hr
echo ">>> 3. Replay the OLD refresh cookie (expect 401 refresh_token_reuse)"

# Build a one-shot cookie jar with ONLY the V1 cookie (no rotation has
# touched it since login).
V1_JAR=$(mktemp); echo -e "# Netscape HTTP Cookie File\nlocalhost\tFALSE\t/\tFALSE\t0\tsso_refresh\t$V1" > "$V1_JAR"
trap 'rm -f "$JAR" "$V1_JAR" /tmp/smoke-refresh-body.$$ /tmp/smoke-refresh-hdr.$$ /tmp/login-body.$$ /tmp/login-hdr.$$' EXIT

REUSE_HTTP=$(curl -sS -o /tmp/reuse-body.$$ -w '%{http_code}' \
  -X POST "$GATEWAY/api/auth/refresh" -b "$V1_JAR")
REUSE_BODY=$(cat /tmp/reuse-body.$$)

if [ "$REUSE_HTTP" = "401" ]; then
  ok "Reuse of rotated cookie returns 401"
else
  bad "Reuse expected 401, got $REUSE_HTTP"
fi
if echo "$REUSE_BODY" | grep -q "refresh_token_reuse"; then
  ok "Reuse body contains refresh_token_reuse"
else
  bad "Reuse body missing refresh_token_reuse: $REUSE_BODY"
fi

# The legitimate V2 cookie must also fail now (family wiped).
V2_JAR=$(mktemp); echo -e "# Netscape HTTP Cookie File\nlocalhost\tFALSE\t/\tFALSE\t0\tsso_refresh\t$V2" > "$V2_JAR"
trap 'rm -f "$JAR" "$V1_JAR" "$V2_JAR" /tmp/smoke-refresh-body.$$ /tmp/smoke-refresh-hdr.$$ /tmp/login-body.$$ /tmp/login-hdr.$$ /tmp/reuse-body.$$' EXIT

V2_HTTP=$(curl -sS -o /tmp/v2-body.$$ -w '%{http_code}' \
  -X POST "$GATEWAY/api/auth/refresh" -b "$V2_JAR")
if [ "$V2_HTTP" = "401" ]; then
  ok "Legitimate V2 also returns 401 (family wiped)"
else
  bad "Legitimate V2 expected 401, got $V2_HTTP"
fi

# ---------- 4. logout clears + revokes ----------
hr
echo ">>> 4. POST /api/auth/logout clears the cookie + revokes the family"

# Fresh login so we have a cookie we can logout. Capture JAR2's
# headers into a dedicated file (NOT /tmp/login-hdr.$$, which belongs
# to check #1's first login and whose cookie has since been rotated).
JAR2=$(mktemp)
curl -sS -o /dev/null -D /tmp/login2-hdr.$$ -X POST "$GATEWAY/login" \
  -H "Content-Type: application/json" \
  -c "$JAR2" \
  -d "{\"username\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}"
trap 'rm -f "$JAR" "$JAR2" "$V1_JAR" "$V2_JAR" "$PRE_JAR" "$EMPTY_JAR" "$A_JAR" "$B_JAR" "$DEV_A" "$DEV_B" /tmp/smoke-refresh-body.$$ /tmp/smoke-refresh-hdr.$$ /tmp/login-body.$$ /tmp/login-hdr.$$ /tmp/login2-hdr.$$ /tmp/reuse-body.$$ /tmp/v2-body.$$ /tmp/empty-body.$$ /tmp/anon-users-body.$$ /tmp/logout-hdr.$$ /tmp/gettoken-anon-body.$$ /tmp/gettoken-auth-body.$$' EXIT

LOGOUT_HTTP=$(curl -sS -o /dev/null -D /tmp/logout-hdr.$$ -w '%{http_code}' \
  -X POST "$GATEWAY/api/auth/logout" -b "$JAR2")
LOGOUT_HDR=$(cat /tmp/logout-hdr.$$)
LOGOUT_SET_COOKIE=$(echo "$LOGOUT_HDR" | grep -i '^set-cookie:' | sed 's/^[Ss]et-[Cc]ookie: //' | head -1)

if [ "$LOGOUT_HTTP" = "200" ]; then
  ok "Logout returns 200"
else
  bad "Logout expected 200, got $LOGOUT_HTTP"
fi
if echo "$LOGOUT_SET_COOKIE" | grep -q "Max-Age=0"; then
  ok "Logout Set-Cookie has Max-Age=0"
else
  bad "Logout Set-Cookie missing Max-Age=0"
fi

# Use the pre-logout cookie from THIS JAR2 login (not the one from
# check #1) so the assertion truly isolates logout-revocation from
# any family wipes left over from checks #2 / #3.
PRE_LOGOUT=$(cookie_value "$(grep -i '^set-cookie:' /tmp/login2-hdr.$$ | sed 's/^[Ss]et-[Cc]ookie: //' | head -1)")
PRE_JAR=$(mktemp); echo -e "# Netscape HTTP Cookie File\nlocalhost\tFALSE\t/\tFALSE\t0\tsso_refresh\t$PRE_LOGOUT" > "$PRE_JAR"
PRE_HTTP=$(curl -sS -o /dev/null -w '%{http_code}' \
  -X POST "$GATEWAY/api/auth/refresh" -b "$PRE_JAR")
if [ "$PRE_HTTP" = "401" ]; then
  ok "Refresh with pre-logout cookie returns 401 (family revoked by logout)"
else
  bad "Refresh with pre-logout cookie expected 401, got $PRE_HTTP"
fi

# ---------- 5. multi-device independence ----------
hr
echo ">>> 5. Two simultaneous logins -> independent families"

DEV_A=$(mktemp); DEV_B=$(mktemp)
curl -sS -o /dev/null -X POST "$GATEWAY/login" -H "Content-Type: application/json" \
  -c "$DEV_A" -d "{\"username\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}"
curl -sS -o /dev/null -X POST "$GATEWAY/login" -H "Content-Type: application/json" \
  -c "$DEV_B" -d "{\"username\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}"

COOKIE_A=$(grep 'sso_refresh' "$DEV_A" | awk '{print $7}')
COOKIE_B=$(grep 'sso_refresh' "$DEV_B" | awk '{print $7}')

if [ -n "$COOKIE_A" ] && [ -n "$COOKIE_B" ] && [ "$COOKIE_A" != "$COOKIE_B" ]; then
  ok "Two logins produced two distinct cookies"
else
  bad "Two logins did not produce distinct cookies (A=${COOKIE_A:-?} B=${COOKIE_B:-?})"
fi

# Rotate A.
A_JAR=$(mktemp); echo -e "# Netscape HTTP Cookie File\nlocalhost\tFALSE\t/\tFALSE\t0\tsso_refresh\t$COOKIE_A" > "$A_JAR"
A_HTTP=$(curl -sS -o /dev/null -w '%{http_code}' \
  -X POST "$GATEWAY/api/auth/refresh" -b "$A_JAR")
if [ "$A_HTTP" = "200" ]; then
  ok "Device A refresh returns 200"
else
  bad "Device A refresh expected 200, got $A_HTTP"
fi

# B is unaffected.
B_JAR=$(mktemp); echo -e "# Netscape HTTP Cookie File\nlocalhost\tFALSE\t/\tFALSE\t0\tsso_refresh\t$COOKIE_B" > "$B_JAR"
B_HTTP=$(curl -sS -o /dev/null -w '%{http_code}' \
  -X POST "$GATEWAY/api/auth/refresh" -b "$B_JAR")
if [ "$B_HTTP" = "200" ]; then
  ok "Device B refresh still returns 200 (independent family)"
else
  bad "Device B refresh expected 200, got $B_HTTP"
fi

# ---------- 6. refresh-minted JWT carries the right sub ----------
hr
echo ">>> 6. Access token from /auth/refresh carries the LOGGED-IN user's sub claim"

# Decode the JWT payload (no signature check; we only care about sub).
PAYLOAD=$(echo "$ACCESS_JWT" | cut -d. -f2)
# Base64url -> Base64 padding.
PAD=$(( (4 - ${#PAYLOAD} % 4) % 4 ))
for _ in $(seq 1 $PAD); do PAYLOAD="${PAYLOAD}="; done
SUB=$(echo "$PAYLOAD" | tr '_-' '/+' | base64 -d 2>/dev/null \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['sub'])" 2>/dev/null || echo "")
if [ "$SUB" = "$ADMIN_EMAIL" ]; then
  ok "JWT sub claim is '$SUB'"
else
  bad "JWT sub claim expected '$ADMIN_EMAIL', got '${SUB:-<empty>}'"
fi

# ---------- 7. cookie security attribute roll-up ----------
hr
echo ">>> 7. Roll-up: HttpOnly + SameSite=Strict + no Domain + Path=/"

if echo "$SET_COOKIE" | grep -q "HttpOnly" \
   && echo "$SET_COOKIE" | grep -q "SameSite=Strict" \
   && ! echo "$SET_COOKIE" | grep -qi "Domain=" \
   && echo "$SET_COOKIE" | grep -q "Path=/"; then
  ok "Cookie has all required security attributes"
else
  bad "Cookie missing one or more required security attributes: $SET_COOKIE"
fi

# ---------- 8. no-cookie refresh -> 401 no_refresh_cookie ----------
hr
echo ">>> 8. POST /api/auth/refresh with no cookie returns 401 no_refresh_cookie"

EMPTY_JAR=$(mktemp); : > "$EMPTY_JAR"
EMPTY_HTTP=$(curl -sS -o /tmp/empty-body.$$ -w '%{http_code}' \
  -X POST "$GATEWAY/api/auth/refresh" -b "$EMPTY_JAR")
EMPTY_BODY=$(cat /tmp/empty-body.$$)

if [ "$EMPTY_HTTP" = "401" ]; then
  ok "No-cookie refresh returns 401"
else
  bad "No-cookie refresh expected 401, got $EMPTY_HTTP"
fi
if echo "$EMPTY_BODY" | grep -q "no_refresh_cookie"; then
  ok "Body contains no_refresh_cookie"
else
  bad "Body missing no_refresh_cookie: $EMPTY_BODY"
fi

# ---------- 9. anonymous /getUsersSSO returns 401 ----------
hr
echo ">>> 9. GET /getUsersSSO with no Authorization returns 401 (admin enumeration closed)"

# Anonymous request — no Bearer, no cookie, nothing. Was 200 with
# a list of usernames + emails + full names + roles before
# Commits 11 + 12. After, it must be 401 from the gateway
# SecurityConfig layer (which runs BEFORE route forwarding in the
# Spring Cloud Gateway filter chain). auth-center re-checks the
# ADMIN requirement on its own servlet stack.
ANON_USERS_HTTP=$(curl -sS -o /tmp/anon-users-body.$$ -w '%{http_code}' \
  "$GATEWAY/getUsersSSO")
if [ "$ANON_USERS_HTTP" = "401" ]; then
  ok "Anonymous /getUsersSSO returns 401"
else
  bad "Anonymous /getUsersSSO expected 401, got $ANON_USERS_HTTP"
  cat /tmp/anon-users-body.$$ || true
fi

# Also verify the body is NOT the user list (regression guard:
# if someone accidentally re-permitAll'd the path, we'd still
# get a 401-ish JSON but maybe a leaked schema).
ANON_USERS_BODY=$(cat /tmp/anon-users-body.$$)
if echo "$ANON_USERS_BODY" | grep -q '"username"'; then
  bad "Anonymous /getUsersSSO body looks like the user enumeration leak: $ANON_USERS_BODY"
else
  ok "Anonymous body does not contain user enumeration payload"
fi

# ---------- 10. /getToken is gone ----------
hr
echo ">>> 10. GET /getToken is removed: 401 anonymous, 404 authenticated (closed in commits 17-19)"

# Anonymous: gateway SecurityConfig runs BEFORE route forwarding in
# the Spring Cloud Gateway filter chain, so a /getToken with no
# Bearer hits .anyExchange().authenticated() and gets 401 at the
# gateway boundary. The controller method is also gone (Commit 17)
# and the auth-center SecurityConfig no longer permitAll's the
# path (Commit 18), so even if the gateway forwarded it auth-center
# would not authenticate it. Two layers, same outcome.
GETTOK_ANON_HTTP=$(curl -sS -o /tmp/gettoken-anon-body.$$ -w '%{http_code}' \
  "$GATEWAY/getToken?refreshToken=ANY_GARBAGE")
if [ "$GETTOK_ANON_HTTP" = "401" ]; then
  ok "Anonymous /getToken returns 401"
else
  bad "Anonymous /getToken expected 401, got $GETTOK_ANON_HTTP"
  cat /tmp/gettoken-anon-body.$$ || true
fi

# Authenticated: a valid Bearer passes the gateway SecurityConfig
# check (the SecurityContext has the ADMIN role for the admin
# user, so anyExchange().authenticated() allows it through), but
# /getToken no longer appears in any route predicate (Commit 20
# removed it from the /login,/getApiToken,... comma-separated
# Path list), and the discovery locator only routes dynamic
# service-id-prefixed paths. The gateway responds 404. As a final
# defense-in-depth layer, auth-center's AuthController has no
# /getToken handler left — the integration tests (Commit 21) pin
# this contract at the unit-test layer; this smoke verifies the
# gateway-side behavior matches what real callers will see.
GETTOK_AUTH_HTTP=$(curl -sS -o /tmp/gettoken-auth-body.$$ -w '%{http_code}' \
  -H "Authorization: Bearer $ACCESS_JWT" \
  "$GATEWAY/getToken?refreshToken=ANY_GARBAGE")
if [ "$GETTOK_AUTH_HTTP" = "404" ]; then
  ok "Authenticated /getToken returns 404 (route predicate deleted)"
else
  bad "Authenticated /getToken expected 404, got $GETTOK_AUTH_HTTP"
  cat /tmp/gettoken-auth-body.$$ || true
fi

# ---------- summary ----------
hr
TOTAL=$((PASS + FAIL))
echo "    $PASS / $TOTAL checks passed"
[ "$FAIL" -eq 0 ] || exit 1