# Modernized SSO — Reference Architecture

A fresh, modernized re-implementation of the legacy `sso_postgres` SSO
microservices, built from scratch with the current Spring stack. This
project is the **reference architecture** for migrating the legacy
code — it proves the dependency graph, the JWT flow, and the runtime
topology work end-to-end before the larger migration begins.

## What's in the box

| Module | Stack | Purpose |
|---|---|---|
| `eurekaserver` | Spring Boot 3.5 + Spring Cloud Netflix Eureka | Service registry. Service-discovery for all 4 modules. |
| `common` | Plain Java library | `User` and `Role` JPA entities, `UserRepository` / `RoleRepository`, `JwtTokenService` (jjwt 0.12.7), shared DTOs. |
| `auth-center` | Spring Boot 3.5 servlet (Tomcat) | Login (`POST /login`), `GET /getApiToken`, `GET /getInfoUser`, `GET /getUsersSSO` (ADMIN-only), `POST /auth/refresh`, `POST /auth/logout`. Issues + validates JWTs. Sets the `sso_refresh` httpOnly cookie on login. |
| `api-gateway` | Spring Cloud Gateway 4 (WebFlux/Netty) | Validates JWTs, injects `X-Authenticated-*` headers, routes `/auth/**` and `/login` to auth-center, and auto-discovers downstream services from Eureka. Also serves the admin-ui SPA at `/admin/**`. |
| `hello-service` | Spring Boot 3.5 reactive (WebFlux) | Reference downstream service. Exposes `/api/hello` and `/api/whoami`. Reachable via the gateway at `/hello-service/**`. |
| `admin-ui` | Vite 5 + React 19 + TS strict + Tailwind | Admin SPA. Built into the api-gateway image (NOT a Maven module). Consumes the 26 sso-admin endpoints. |

Versions: **Java 21**, **Spring Boot 3.5.3**, **Spring Cloud 2025.0.0 ("Northfields")**, **jjwt 0.12.7**, **Node 20** (for the SPA build).

## Architecture

```
            ┌────────────┐
            │  Browser   │
            │  / curl    │
            └─────┬──────┘
                  │  HTTPS
                  ▼
        ┌─────────────────────┐
        │     api-gateway     │  8080 — WebFlux
        │  (JWT validation,   │
        │   header injection) │
        └─────┬───────────────┘
              │
   ┌──────────┼──────────┬──────────────┐
   │          │          │              │
   ▼          ▼          ▼              ▼
auth-center  hello-svc  ...other     eureka
  8081        8082      services     8761
   │                       ▲
   │   ┌───────────────┐   │
   └──▶│   postgres    │◀──┘     (registry + config for everyone)
       │     5432      │
       └───────────────┘
```

### Trust model

The **api-gateway is the trust boundary**:

1. **auth-center** signs JWTs with HS256 (`sso.jwt.secret`).
2. **api-gateway** validates the JWT on every protected request, populates a reactive `SecurityContext` with an `AuthPrincipal`, and injects `X-Authenticated-User`, `X-Authenticated-Roles`, `X-Authenticated-Token-Type` into the downstream request via a `GlobalFilter`.
3. **Downstream services** (e.g. `hello-service`) trust the `X-Authenticated-*` headers. They do **NOT** re-validate the JWT. This is safe only when the service is reachable only via the gateway and the network path is locked down.

If you need a service that's exposed directly to the internet (bypassing the gateway), it must re-validate the JWT itself.

### Refresh-token flow (RFC 9700 §4.14)

`auth-center` issues an `sso_refresh` cookie on `POST /login` and
**rotates it on every `POST /api/auth/refresh`** per the OAuth 2.0
Security Best Current Practice (RFC 9700, Jan 2025). The MVP flow
that the legacy code shipped with — "any non-empty `sso_refresh`
cookie mints a JWT for the first enabled user in the DB" — was
closed in `feat/sso-admin-query-catalog`. There is no fall-back:
every cookie the store does not authorize is a 401.

| Step | What happens |
|---|---|
| `POST /login` | `JsonLoginFilter` calls `RefreshTokenStore.mint(username, userId, familyId)`. The raw UUID is set in the response body and the `Set-Cookie` header. Cookie attrs: `HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000` (30 days, mirrors the Redis TTL). |
| `POST /api/auth/refresh` | `store.rotate(raw)`: `GET sso:refresh:hash:<sha256>` → if live, `MULTI`-GETDEL + wipe family + write tombstone + mint replacement in the SAME family. Cookie value changes every call. |
| Replay of an already-rotated cookie | Tombstone at `sso:refresh:replay:<sha256>` + GETDEL'd hash → `ReuseDetected` → `revokeFamily(...)`. **The entire family (including any newer legitimate token) is wiped.** RFC 9700 §4.14.2 mandates this: a stolen refresh cookie must not be usable after a single successful refresh. The SPA's single-flight 401 handler logs the user out. |
| `POST /api/auth/logout` | `store.revokeToken(raw)` deletes every live token in the family + clears the cookie (`Max-Age=0`). |
| Multi-device | Each login is a new independent family. Rotating one device's cookie does not invalidate other devices. |
| Store unavailable | `DataAccessException` (Redis timeout / unreachable) → controller returns `503 store_unavailable` on login or `401 store_unavailable` on refresh / logout. **`fail-open` is hard-coded off** (`sso.refresh-token.fail-open: false`). |

Invariants:

- **Server-side source of truth.** The cookie value is opaque to
  the server; the actual `username` / `userId` / `familyId` is read
  from Redis. The DB user lookup only happens to resolve
  `username → UserDetails` for the JWT, not for cookie validation.
- **SHA-256 at rest.** The Redis key is the SHA-256 hex of the
  raw token; the raw value only exists on the wire (cookie +
  JSON response body) and in the user's browser (RFC 9700
  §4.9.3).
- **Atomic rotation.** The rotate path uses Spring Data Redis
  `SessionCallback` with MULTI/EXEC so the GETDEL + family-wipe +
  tombstone-write is a single atomic operation. Concurrent refresh
  attempts from two tabs racing the same cookie resolve to one
  `Rotated` + one `ReuseDetected` → family wipe → both tabs 401 →
  SPA logs out. RFC 9700-mandated behaviour.
- **Cookie name ↔ key prefix coupling.**
  `JsonLoginFilter.REFRESH_COOKIE_NAME = "sso_refresh"` and
  `sso.refresh-token.key-prefix: sso:refresh` MUST change together.
  Otherwise a cookie from a previous deployment could be replayed
  against a different key namespace.

Config: `auth-center/src/main/resources/application.yml` → block
`sso.refresh-token.*` (`ttl-seconds`, `key-prefix`, `fail-open`).

### Operational notes

- **Redis persistence — disabled by design.** Compose runs Redis
  with `--save "" --appendonly no`. Refresh tokens have a 30-day
  TTL on every key; if Redis loses state, the worst case is
  every active user re-logs in once. There is **no `redis-data`
  volume mount**. Acceptable for an admin SPA.
- **Redis memory footprint.** ~200 bytes per active session
  (one hash key ~100 bytes JSON + key overhead + one family-set
  member ~64 bytes). 10k users × 10 devices ≈ 100k sessions ×
  200 bytes = 20 MB.
- **Redis is a hard dependency at startup.** `auth-center`
  `depends_on.redis` has `condition: service_healthy` in
  `docker-compose.yml`. A Redis crash mid-flight degrades to
  401s — there is no fail-open escape hatch.
- **Single-node Redis is the target.** Lettuce is Sentinel-aware,
  so the upgrade path is `spring.data.redis.sentinel.*` only — no
  code change.
- **Logging.** Successful rotation → INFO with family (last 8
  chars). Reuse detection → WARN with `username` + `familyId` +
  `hash_prefix` + remote IP. Store unavailable → ERROR with
  Redis host:port + exception class.

### Deploy cutover (hard-cutover by design)

The bypass-era `MVP refresh-token flow` is removed; old cookies
are NOT migrated. Rollout procedure:

```bash
# 1. Announce a 1-minute downtime window.
# 2. Stop auth-center.
docker compose stop auth-center
# 3. Bring redis up first; verify healthy.
docker compose up -d redis
docker compose ps    # redis must show (healthy)
# 4. Build + start auth-center with the new image.
docker compose build auth-center
docker compose up -d auth-center
# 5. Verify.
docker compose ps    # all services healthy
bash admin-ui/scripts/smoke-auth-refresh.sh    # 8/8
```

**Expected user impact:** every user with a pre-deploy cookie gets
a 401 on their next API call → SPA redirects to login → re-auth.
This is by design (the legacy MVP cookie was a placeholder anyway —
no legitimate user data was stored client-side).

**Rollback path.** Rolling back to the MVP code requires flushing
Redis first; otherwise the rolled-back code will treat every
cookie as valid and mint tokens for the first enabled user,
recreating the bypass. The safer choice is to go forward.

### Dynamic routes

`api-gateway` auto-creates a route per service registered with Eureka, lowercased service-id as the path prefix. For example, `hello-service` (registered with Eureka as `HELLO-SERVICE`) gets the route `lb://HELLO-SERVICE` mounted at `/hello-service/**`. The `api-gateway` itself is excluded from the routes via the discovery locator's `include-expression` to prevent self-reference.

## Prerequisites

- **Java 21** (`java -version` must show 21.x).
- **Maven 3.9+** (the project uses the `spring-boot-starter-parent` BOM).
- **Postgres 16** — locally or via Docker.
- *(Optional)* **Docker + Docker Compose** for the one-shot stack.

## Quick start — `mvn`

```bash
# 1. Build everything
mvn clean package

# 2. Start Postgres and create the schema (uses your local Postgres
#    cluster; adjust -U/-d if your setup is different).
psql -U postgres -c "CREATE DATABASE sso;"
psql -U postgres -c "CREATE USER sso WITH PASSWORD 'change-me-in-prod';"
psql -U postgres -c "GRANT ALL ON DATABASE sso TO sso;"
psql -U postgres -d sso -f postgres/init/01-create-sso-db.sh

# 3. Start the services in 4 terminals (in this order):
java -jar eurekaserver/target/eurekaserver.jar
java -jar auth-center/target/auth-center.jar
java -jar api-gateway/target/api-gateway.jar
java -jar hello-service/target/hello-service.jar

# 4. Smoke-test the full flow
TOKEN=$(curl -s -X POST http://localhost:8080/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"ChangeMe-Now-Please-123!"}' | jq -r .token)

curl -s http://localhost:8080/hello-service/api/hello \
  -H "Authorization: Bearer $TOKEN"
# → {"message":"Hello, admin!","user":"admin","roles":["USER","ADMIN"],...}
```

The `admin` user is created on first start by `DataInitializer` with the password from `sso.bootstrap.admin-password` (default: `ChangeMe-Now-Please-123!`). Set `SSO_BOOTSTRAP_ENABLED=false` for production.

## Quick start — `docker compose`

```bash
cp .env.example .env       # edit secrets
docker compose build       # build all 4 service images
docker compose up -d       # start the stack

# Health
docker compose ps          # all 5 services should be (healthy)
curl -fsS http://localhost:8761/actuator/health   # eureka
curl -fsS http://localhost:8080/actuator/health   # gateway
curl -fsS http://localhost:8081/actuator/health   # auth-center

# Get a JWT and call the downstream service through the gateway
TOKEN=$(curl -s -X POST http://localhost:8080/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"ChangeMe-Now-Please-123!"}' | jq -r .token)

curl -s http://localhost:8080/hello-service/api/hello \
  -H "Authorization: Bearer $TOKEN"

# Tear down
docker compose down        # keeps the postgres volume
docker compose down -v     # also wipes the database
```

## API surface

All endpoints below are served by **api-gateway** on port `8080` unless
otherwise noted. Trailing `/auth` is stripped before forwarding to
`auth-center` (see `api-gateway/src/main/resources/application.yml`).

| Method | Path | Auth | Description |
|---|---|---|---|
| `POST` | `/login` | none | JSON body `{"username","password"}` → `{token, refreshToken, ...}` (200) or 401 |
| `GET`  | `/getApiToken`     | required | Issues a long-lived API token (typ=api) for the authenticated user |
| `GET`  | `/getInfoUser`     | required | Returns the authenticated user's profile (id, username, email, roles) |
| `GET`  | `/getUsersSSO`     | required, `ADMIN` | Lists all users in the SSO |
| `GET`  | `/actuator/health` | none | Health probe (gateway + all downstream services) |
| `GET`  | `/actuator/info`    | none | Build info |
| `GET`  | `/hello-service/api/hello`   | required | Reference downstream endpoint. Returns `{message, user, roles, ...}` |
| `GET`  | `/hello-service/api/whoami` | required | Diagnostic: echoes the `X-Authenticated-*` headers |

### `sso-admin` (User/Role/Group CRUD + activation)

Served by the `sso-admin` microservice (port 8083) behind the
gateway at `/sso-admin/**`. The legacy `sso-service` URL
surface is preserved — existing clients do not need to change.
All business endpoints require the `ADMIN` role; the public
activation/restore links do not.

| Method | Path | Auth | Description |
|---|---|---|---|
| `POST` | `/sso-admin/createAccount`        | `ADMIN` | Creates a user in `active=true, enabled=false` state, issues an activation token, sends the activation email |
| `PUT`  | `/sso-admin/updateAccount`        | `ADMIN` | Updates mutable user fields; `null` leaves unchanged; non-null `roleNames` REPLACES the role set |
| `POST` | `/sso-admin/activateAccount`     | **public** | Activates a user via the email link; body is `{token, password}`; sets `enabled=true` and BCrypts the password. Replaces the legacy GET-with-password-query shape (commits 2 + 5). |
| `GET`  | `/sso-admin/forgotPassword?email=…` | **public** | Issues a restore token and emails the user. Always 200 (no email enumeration) |
| `POST` | `/sso-admin/restorePassword`     | **public** | Restores the password via the restore token; body is `{token, password}`. Replaces the legacy GET-with-password-query shape (commits 3 + 6). |
| `GET`  | `/sso-admin/getUsers`             | `ADMIN` | Lists all users (id, fullName, username, ldap, active, roleNames) |
| `GET`  | `/sso-admin/getRolesByUsername?username=…` | `ADMIN` | Returns the role names of the given user |
| `GET`  | `/sso-admin/user/roles?userId=…`  | `ADMIN` | Same shape as `getRolesByUsername`, looked up by id |
| `POST` | `/sso-admin/bindUserRole`         | `ADMIN` | Idempotently binds a role to a user |
| `DELETE` | `/sso-admin/unbindUserRole?userId=…&roleId=…` | `ADMIN` | Idempotently unbinds |
| `POST` | `/sso-admin/role/createRole`      | `ADMIN` | Creates a role |
| `PUT`  | `/sso-admin/role/updateRole`      | `ADMIN` | Updates a role |
| `GET`  | `/sso-admin/role/getRoles`        | `ADMIN` | All roles |
| `GET`  | `/sso-admin/role/getRolesOwn`     | `ADMIN` | All roles except `ADMIN_USUARIOS_OPERADORAS` (legacy exclusion) |
| `GET`  | `/sso-admin/role/users?roleId=…`  | `ADMIN` | Users that have the role |
| `GET`  | `/sso-admin/role/users/checked?roleId=…` | `ADMIN` | All users with a `checked` flag (multi-select UI) |
| `POST` | `/sso-admin/group`                | `ADMIN` | Idempotent group upsert (by name) |
| `GET`  | `/sso-admin/group`                | `ADMIN` | Lists groups (with `memberCount`) |
| `POST` | `/sso-admin/group/bindUserGroup`  | `ADMIN` | Idempotently binds a user to a group |
| `POST` | `/sso-admin/microservice/save`    | `ADMIN` | Creates a microservice. `serviceId` must be unique |
| `PUT`  | `/sso-admin/microservice/update`  | `ADMIN` | Updates a microservice (`id` required) |
| `GET`  | `/sso-admin/microservice/getMicroservices` | `ADMIN` | Lists all microservices |
| `GET`  | `/sso-admin/microservice/getMicroservice?serviceId=…` | `ADMIN` | Looks up a microservice by its natural key |
| `GET`  | `/sso-admin/microservice/{id}`    | `ADMIN` | Looks up a microservice by id |
| `DELETE` | `/sso-admin/microservice/{id}`   | `ADMIN` | Deletes a microservice (cascades through `ENDPOINT_MICROSERVICE`) |
| `POST` | `/sso-admin/endpoint/save`        | `ADMIN` | Creates an endpoint. Uniqueness is `(PATH, METHOD, DESCRIPTION)` |
| `PUT`  | `/sso-admin/endpoint/update`      | `ADMIN` | Updates an endpoint |
| `GET`  | `/sso-admin/endpoint/getEndpoints` | `ADMIN` | Lists all endpoints (with their bound `microserviceIds`) |
| `GET`  | `/sso-admin/endpoint/{id}`        | `ADMIN` | Looks up an endpoint by id |
| `DELETE` | `/sso-admin/endpoint/{id}`       | `ADMIN` | Deletes an endpoint |
| `POST` | `/sso-admin/endpoint/{id}/microservice/{microserviceId}` | `ADMIN` | Idempotently binds a microservice to an endpoint |
| `DELETE` | `/sso-admin/endpoint/{id}/microservice/{microserviceId}` | `ADMIN` | Idempotently unbinds |
| `GET`  | `/sso-admin/endpoint/{id}/microservices/checked` | `ADMIN` | All microservices with a `checked` flag (multi-select UI) |
| `POST` | `/sso-admin/endpoint/{id}/role/{roleId}` | `ADMIN` | Idempotently grants a role access to invoke this endpoint |
| `DELETE` | `/sso-admin/endpoint/{id}/role/{roleId}` | `ADMIN` | Idempotently revokes |
| `GET`  | `/sso-admin/endpoint/{id}/roles/checked` | `ADMIN` | All roles with a `checked` flag (multi-select UI) |
| `POST` | `/sso-admin/route/save`           | `ADMIN` | Creates a route. `idParent=0` (legacy root sentinel) is normalized to `null` |
| `PUT`  | `/sso-admin/route/update`         | `ADMIN` | Updates a route |
| `GET`  | `/sso-admin/route/getRoutes`      | `ADMIN` | Lists all routes |
| `GET`  | `/sso-admin/route/getRoutesByParent?idParent=…` | `ADMIN` | Roots if `idParent` is omitted or `0`; direct children otherwise |
| `GET`  | `/sso-admin/route/{id}`           | `ADMIN` | Looks up a route by id |
| `DELETE` | `/sso-admin/route/{id}`          | `ADMIN` | Deletes a route (cascades to children) |
| `POST` | `/sso-admin/route/{id}/role/{roleId}` | `ADMIN` | Idempotently grants a role access to see this route |
| `DELETE` | `/sso-admin/route/{id}/role/{roleId}` | `ADMIN` | Idempotently revokes |
| `GET`  | `/sso-admin/route/{id}/roles/checked` | `ADMIN` | All roles with a `checked` flag (multi-select UI) |

Activation and restore-password emails are rendered from
Freemarker templates at
`sso-admin/src/main/resources/templates/{activation,restore}-account.html`
and sent through SMTP (MailHog in dev, real relay in prod). The
links inside the email point at the gateway, not the sso-admin
container directly, so they work from any browser hitting the
public hostname.

Anything not on this list returns **401** by the gateway's default-deny rule.

## Admin UI (admin-ui/)

A React 19 SPA that consumes all 26 sso-admin endpoints. Served by
the api-gateway at `/admin/**` (single origin in production).

- **Stack**: Vite 5, React 19, TypeScript 5.6 strict (with
  `noUncheckedIndexedAccess` and `exactOptionalPropertyTypes`),
  React Router v7, TanStack Query v5, TailwindCSS v3, Zod.
- **Auth model**: access token in memory (never `localStorage`),
  refresh in `httpOnly; SameSite=Strict; Path=/auth` cookie set
  by `auth-center` on login. The SPA's `ApiClient` does a
  single-flight `/auth/refresh` on a 401 and retries the original
  request once.
- **CSP**: strict `default-src 'self'` (no `'unsafe-inline'`, no
  `'unsafe-eval'`), `frame-ancestors 'none'`, served via a meta
  tag in `admin-ui/index.html`.
- **CORS**: the api-gateway and auth-center read
  `SSO_CORS_ALLOWED_ORIGINS` (comma-separated) and call
  `setAllowedOrigins(...)` (real allowlist, never `*`) with
  `setAllowCredentials(true)`. The default in dev is
  `http://localhost:8080,http://localhost:5173`.

### Run the SPA in dev

```bash
cd admin-ui
npm ci                  # one-time
npm run dev             # http://localhost:5173/admin/
npm test                # vitest: 40 unit/integration tests
npm run e2e             # playwright: requires gateway running on :8080
```

Vite proxies `/api/**` to `http://localhost:8080`, so the SPA sees
a single origin (5173) even though the API lives on the gateway.
Start the gateway first (`mvn -pl api-gateway spring-boot:run` or
`docker compose up api-gateway`).

### Build the SPA into the gateway image

The `api-gateway` Dockerfile is multi-stage:

1. `node-spa` (`node:20-alpine`) runs `npm ci && npm run build`.
2. `java-build` (`maven:3.9-eclipse-temurin-21`) copies the SPA
   `dist/` into `src/main/resources/static/admin/` **before**
   `mvn package`, so the SPA files end up inside the fat jar.
3. The runtime image (`eclipse-temurin:21-jre-jammy`) serves the
   SPA at `/admin/**` via `AdminUiRouter.kt` (a
   `RouterFunction<ServerResponse>` that handles static assets
   and the SPA history-mode fallback to `index.html`).

After `docker compose up -d --build`, the SPA is reachable at
`http://localhost:8080/admin/`. Verified with:

```bash
curl -sI http://localhost:8080/admin/                         # 200 text/html
curl -sI http://localhost:8080/admin/users                   # 200 text/html
curl -sI http://localhost:8080/admin/assets/index-XXXXXXXX.js # 200 js
```

### Playwright E2E

`admin-ui/e2e/auth.spec.ts` covers the happy path:

1. Land on `/admin/`, expect redirect to `/login`.
2. Submit credentials, expect `/admin/users` with the seeded admin row.
3. Assert `localStorage` and `sessionStorage` are empty (token
   stays in JS heap).
4. Assert the `sso_refresh` cookie is `HttpOnly`.
5. Click logout, expect `/login` again and the cookie wiped.
6. Capture all console errors and assert no CSP violations.

### Headers propagated by the gateway to downstream services

| Header | Value |
|---|---|
| `X-Authenticated-User`       | JWT `sub` claim (the username) |
| `X-Authenticated-Roles`      | Comma-separated role names |
| `X-Authenticated-Token-Type` | `access` or `api` |

## Environment variables

| Var | Default | Where | Purpose |
|---|---|---|---|
| `JWT_SECRET` | `change-me-…-1234567890` (dev placeholder) | auth-center, api-gateway, **sso-admin** | HMAC key. **MUST match across all three**. Min 32 bytes; `JwtTokenService` refuses to start with a shorter key. |
| `DB_URL` | `jdbc:postgresql://localhost:5432/sso` | auth-center, **sso-admin** | JDBC URL |
| `DB_USER` | `sso` | auth-center, **sso-admin** | DB username |
| `DB_PASSWORD` | `change-me-in-prod` | auth-center, **sso-admin** | DB password |
| `EUREKA_URL` | `http://localhost:8761/eureka` | auth-center, api-gateway, hello-service, **sso-admin** | Service registry URL |
| `REDIS_HOST` | `localhost` | auth-center | Redis host for the refresh-token store. Compose service name `redis` inside the stack; loopback on host runs. |
| `REDIS_PORT` | `6379` | auth-center | Redis port |
| `REDIS_PASSWORD` | (empty) | auth-center | Redis password. **MUST** be set in production via secret manager. Empty default is for dev only. |
| `SSO_BOOTSTRAP_ENABLED` | `true` | auth-center | Set `false` in production to disable the default admin seeder |
| `SSO_ADMIN_USERNAME` | `admin` | auth-center | Bootstrap admin username |
| `SSO_ADMIN_PASSWORD` | `ChangeMe-Now-Please-123!` | auth-center | Bootstrap admin password. **Set in production.** |
| `SSO_ADMIN_EMAIL` | `admin@example.com` | auth-center | Bootstrap admin email |
| `PORT` | `8082` | hello-service | Override the hello-service port |
| `SSO_ADMIN_PORT` | `8083` | sso-admin | Override the sso-admin port |
| `SMTP_HOST` | `mailhog` | sso-admin | SMTP relay host. In dev, the `mailhog` service. In prod, your mail relay. |
| `SMTP_PORT` | `1025` | sso-admin | SMTP port. MailHog default is 1025. |
| `SMTP_FROM` | `no-reply@example.com` | sso-admin | `From:` header for activation and restore emails |
| `SSO_ACTIVATION_URL` | `http://localhost:8080/admin/activate` | sso-admin | Public URL the user clicks in the activation email — points at the SPA landing page that hosts the password form (POSTs to `/sso-admin/activateAccount`) |
| `SSO_RESTORE_URL` | `http://localhost:8080/admin/restore-password` | sso-admin | Public URL the user clicks in the restore-password email — points at the SPA landing page that hosts the password form (POSTs to `/sso-admin/restorePassword`) |
| `SSO_EMAIL_COMPANY` | `Example Inc.` | sso-admin | Company name shown in the email header |
| `SSO_EMAIL_APP_NAME` | `SSO Modernizado` | sso-admin | Application name shown in the email |
| `SSO_EMAIL_LOGO_URL` | `https://www.example.com/img/logo.png` | sso-admin | Logo URL embedded in the email |

## Tests

```bash
mvn test                              # all 6 backend modules, ~128 tests
mvn -pl auth-center test              # 10 tests
mvn -pl api-gateway test              # 11 tests
mvn -pl hello-service test            # 7 tests
mvn -pl common test                   # 11 tests
mvn -pl eurekaserver test             # 1 test (context load)
mvn -pl sso-admin test                # 95 tests (78 unit + 17 integration)

# Frontend
cd admin-ui && npm test               # vitest: 40 unit/integration tests
cd admin-ui && npm run e2e            # playwright: requires gateway running
```

`auth-center` and the JWT tests use **H2 in PostgreSQL compatibility mode** so the suite runs without a live Postgres. To exercise the real Postgres path, run with `--testcontainers` (or, in CI, the compose stack).

## Module layout

```
modernize/
├── pom.xml                       # parent POM — Spring Boot 3.5.3 + Spring Cloud 2025.0.0 BOM
├── docker-compose.yml            # full stack: postgres + eureka + auth-center + gateway + hello + sso-admin + mailhog
├── .env.example                  # env template for docker compose
├── .dockerignore
├── eurekaserver/                 # :8761 — Eureka server
├── common/                       # entities, repos, JWT service, DTOs
├── auth-center/                  # :8081 — login + token issuance + /auth/refresh + /auth/logout
├── api-gateway/                  # :8080 — reactive gateway (WebFlux) + serves admin-ui SPA at /admin/**
├── hello-service/                # :8082 — reference downstream service
├── sso-admin/                    # :8083 — User/Role/Group CRUD + activation (Phase 1) + Microservice/Endpoint/Route CRUD + bindings (Phase 2)
├── query-service/                # :8084 — read-side catalog (QUERY / ROLE_QUERY / WRITE_DEFINITION / ROLE_WRITE)
├── provisioner/                  # microservice registry provisioner (calls /sso-admin/microservices/upsertByName)
├── notification-service/         # :8085 — multichannel (SMS / email / push) consumer from RabbitMQ, providers + circuit breakers
├── admin-ui/                     # React 19 SPA — built into api-gateway image (NOT a Maven module)
└── postgres/
    └── init/
        ├── 01-create-sso-db.sh                # base users / role / role_users
        ├── 02-create-sso-admin-tables.sh      # groups / user_group (Phase 1)
        ├── 03-create-sso-admin-phase2-tables.sh # MICROSERVICE / ENDPOINT / ROUTE + joins (Phase 2)
        └── 05-create-query-tables.sh          # QUERY / ROLE_QUERY / WRITE_DEFINITION / ROLE_WRITE (query-service)
```

## notification-service

First broker-driven module. Reads `NotificationMessage` envelopes
from the `notifications` topic exchange (one queue per channel:
`notif.sms`, `notif.email`, `notif.push`), persists each attempt
to `notification_log` with idempotency on `notification_id`,
and routes through one of N providers per channel with circuit
breakers and failover.

See [`notification-service/README.md`](notification-service/README.md)
for full architecture, env vars, Rabbit topology, provider
configuration, and how to enable / disable providers via
`POST /actuator/providers/refresh` (no restart).

## Security notes (for production)

1. **Set a real `JWT_SECRET`** — generate 64+ bytes from a CSPRNG, store in a secret manager. The dev placeholder is in version control.
2. **Set `SSO_BOOTSTRAP_ENABLED=false`** and provision users via a dedicated admin endpoint or migration. The `DataInitializer` logs the username at INFO but never the password.
3. **Set a real `DB_PASSWORD`** and use a managed Postgres (RDS, Cloud SQL, etc.) with TLS and a least-privilege role.
4. **Lock down the network path** between api-gateway and downstream services. The `X-Authenticated-*` headers are advisory and can be spoofed by anyone who can reach the downstream directly.
5. **Refresh the bootstrap password** on first deploy. `DataInitializer` skips seeding if the user already exists, so rotating the password requires either an admin endpoint or a DB migration.
6. **BCrypt cost** is 12 (`AuthenticationConfig.passwordEncoder`). Adjust up if your hardware can afford it.
7. **`GET /getUsersSSO` is ADMIN-only.** Until commits 11+12 on
   `feat/sso-admin-query-catalog` it was permit-all at both the
   api-gateway and auth-center layers, returning every active
   user's username + email + fullName + roles to any anonymous
   caller (PII leak). It is now gated by `hasAuthority("ADMIN")`
   on both layers — the anonymous request returns 401 before
   any controller runs. The integration test
   `AuthCenterIntegrationTest#getUsersSsoWithoutTokenReturns401`
   pins the contract. Anyone reintroducing `permitAll()` on this
   path should fail CI.

## Migration roadmap (how this maps to the legacy code)

| Step | Status | What it covers |
|---|---|---|
| 1 | ✅ | Parent POM + Eureka server |
| 2 | ✅ | `common` module skeleton (entities, JPA repos) |
| 3 | ✅ | `common` JWT service (jjwt 0.12.7, unit-tested) |
| 4 | ✅ | `auth-center` with login + getApiToken + JPA-backed `UserDetailsService` |
| 5 | ✅ | `api-gateway` reactive security with JWT validation and routes |
| 6 | ✅ | Dynamic routes + global filters (X-Authenticated-* injection) |
| 7 | ✅ | Default admin seeder (`DataInitializer`) + hello-world downstream service |
| 8 | ✅ | Dockerfiles + `docker-compose.yml` for the full stack |
| 9 | ✅ | **Phase 1** of the `sso-service` port: `sso-admin` with User/Role/Group CRUD + activation + restore-password flow (55 tests) |
| 10 | ✅ | **Phase 2** of the `sso-service` port: `sso-admin` with Microservice/Endpoint/Route CRUD + bindings (33 new tests, 95 total in sso-admin) |
| 11 | ✅ | **Admin UI**: React 19 SPA at `admin-ui/` covering all 26 sso-admin endpoints. Served by api-gateway at `/admin/**`. 40 unit tests + 1 Playwright happy-path |

### `sso-service` migration plan (phased)

The legacy `sso-service` (14 controllers, 15 services, 30+ tables) is
migrated in 6 phases. Phase 1 is shipped; phases 2–6 are planned but
not yet scheduled — each one is an independent commit when picked up.

| Phase | Module | Scope | Status |
|---|---|---|---|
| 1 | `sso-admin` | User/Role/Group CRUD + activation/restore + SMTP | ✅ shipped |
| 2 | `sso-admin` | Microservice/Endpoint/Route CRUD + bindings (7 tables) | ✅ shipped |
| 3 | `sso-admin` | App/Screen/Brick/BackendController (RethinkDB → Postgres JSONB) | pending |
| 4 | `sso-admin` | Reports (CRUD + executor + optional Redis cache, 12 tables) | pending |
| 5 | `sso-admin` | File upload + External endpoints proxy (2 tables) | pending |
| 6 | `sso-admin` | WebSocket with Postgres LISTEN/NOTIFY (replaces RethinkDB cursor) | pending |
