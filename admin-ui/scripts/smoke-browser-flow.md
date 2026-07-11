# Browser smoke flow — kind=QUERY end-to-end

Manual verification that the admin-ui form correctly creates a `kind=QUERY`
microservice, the sso-admin backend persists it, the provisioner spins up a
new `query-service-<instance>` container, and the gateway discovers it.

## Pre-flight

1. **Stack is up.**
   ```bash
   docker ps --format 'table {{.Names}}\t{{.Status}}'
   ```
   Expect 7+ containers UP and at least these healthy:
   `sso-postgres`, `sso-eureka`, `sso-auth-center`, `sso-admin`,
   `sso-api-gateway`, `sso-provisioner`. The `query-service-smoke-*`
   containers are leftovers from previous runs — fine to ignore or remove
   (`docker rm -f query-service-smoke-*`).

2. **Backend smoke is green.** If the stack is fresh, run the backend
   smoke first to confirm the data path before clicking through the UI:
   ```bash
   bash admin-ui/scripts/smoke-kind-query.sh
   ```
   Expect `✅ PASS — kind=QUERY was stored correctly`. If this fails,
   the UI won't fix it; debug the backend first.

3. **Browser is pointed at the gateway.**
   - URL: `http://localhost:8080/admin/microservices` (Vite dev server is
     proxied through the gateway when running in compose; otherwise the
     `admin-ui` dev server defaults to `:5173` and proxies `/api/*` to
     `:8080`).
   - Login: `admin` / `ChangeMe-Now-Please-123!` (the dev admin seeded by
     `04-add-microservice-query-fields.sh`).

## Flow

### Step 1 — Open Microservicios page

Navigate to `/admin/microservices` (sidebar entry **Microservicios**).

You should see a table listing existing microservices. Each row shows
`serviceId`, `description`, `requestUri`, and a column that switches
based on `kind`:
- **REST rows** → `targetUrlHost:targetUrlPort/targetUriPath`
- **QUERY rows** → `dialect (instanceName)`

The "Nuevo microservicio" button (top-right) opens the drawer.

### Step 2 — Open the create drawer

Click **Nuevo microservicio**. The drawer slides in from the right.

You'll see a `Form<MicroserviceFormValues>` with these top-level fields:

- `serviceId` — text input (required)
- `requestUri` — text input (required)
- `description` — textarea (optional)

followed by a **Kind** radio group:

- ○ **REST routing** — *"Regla clásica de gateway (host + port + path)."*
- ○ **Query service** — *"Levanta un contenedor query-service dedicado
  para este microservicio."*

### Step 3 — Choose QUERY kind

Click the **Query service** radio. The form re-renders the QUERY block:

- `dialect` — select (postgres, oracle, sqlserver)
- `jdbcUrl` — text input (required, must start with `jdbc:`)
- `dbUsername` — text input
- `dbPassword` — password input (optional; stored null on save)
- `poolSize` — number input (default 10)
- `instanceName` — text input (must be unique across QUERY rows; the
  provisioner uses this for the Docker container name suffix)

The original REST fields (`targetUrlHost`, `targetUrlPort`,
`targetUriPath`) are still visible but become irrelevant — for QUERY rows
they're not what the gateway routes on.

### Step 4 — Fill the form

Example values (use a unique `instanceName` so the smoke stays idempotent):

| Field         | Value                                   |
|---------------|-----------------------------------------|
| serviceId     | `myshop-users`                          |
| requestUri    | `/api/myshop/**`                        |
| description   | `MyShop users (QUERY)`                  |
| kind          | **Query service**                       |
| dialect       | `postgres`                              |
| jdbcUrl       | `jdbc:postgresql://postgres:5432/sso`   |
| dbUsername    | `sso`                                   |
| dbPassword    | (leave blank — your local pg password)  |
| poolSize      | `5`                                     |
| instanceName  | `myshop-users`                          |

> ℹ️ The Docker socket is mounted **only** on `sso-provisioner`. The
> `sso-admin` itself does NOT have `/var/run/docker.sock`. Every
> `kind=QUERY` create goes through the provisioner's HTTP API.

### Step 5 — Submit

Click **Crear**. The drawer closes; a toast appears:

> *"Microservicio QUERY creado; aprovisionando…"*

Behind the scenes:
1. admin-ui `POST /api/sso-admin/microservice/save` with the full
   `MicroserviceRequest` payload — `kind`, `dialect`, `jdbcUrl`,
   `dbUsername`, `dbPassword`, `poolSize`, `instanceName` included.
2. sso-admin `MicroserviceService.create` writes the row with `kind=QUERY`
   and calls `provisioner.provision(...)`.
3. Provisioner `DockerSocket.createAndStart` POSTs
   `/v1.43/containers/create` with:
   - Image: `eurekatic/query-service:1.0.0-SNAPSHOT`
   - Env: `QUERY_DS_DIALECT`, `QUERY_DS_URL`, `QUERY_DS_USERNAME`,
     `QUERY_DS_PASSWORD`, `QUERY_DS_POOL_SIZE`, `QUERY_INSTANCE_NAME`,
     `EUREKA_URL`, `JWT_SECRET`, `QUERY_CATALOG_BASE_URL`
   - Network: `${COMPOSE_PROJECT_NAME:-modernize}_default`
4. sso-admin's `EurekaReadinessProbe` waits up to **45 seconds** for the
   new `query-service-myshop-users` instance to register with Eureka.
5. The endpoint returns **HTTP 201** once Eureka confirms the registration.

If the toast is followed by an error banner ("Microservicio creado"
without the QUERY suffix), the new fields didn't reach the backend —
check `docker logs sso-admin` for a malformed record warning.

### Step 6 — Verify the row

Refresh the table (F5). You should see a new row:

```
myshop-users | MyShop users (QUERY) | /api/myshop/** | postgres (myshop-users)
```

Click the row's edit icon to open the drawer again — the QUERY block
should be pre-filled with the values you saved.

### Step 7 — Verify the container is up

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep myshop-users
```

Expect:
```
query-service-myshop-users   Up 1 minute (healthy)
```

### Step 8 — Verify Eureka registration

Open `http://localhost:8761` (Eureka dashboard, no auth) and check the
**Instances currently registered** list. Look for
`QUERYSERVICE-MYSHOP-USERS` (Eureka uppercases the service id).

### Step 9 — Hit the new query-service

The gateway's discovery locator auto-creates a route at
`/<serviceId>/**`. With `serviceId = myshop-users` and
Eureka service-id `query-service-myshop-users`, the path is:

```bash
curl -sS -X POST http://localhost:8080/query-service-myshop-users/query \
  -H "Authorization: Bearer <your-jwt>" \
  -H "Content-Type: application/json" \
  -d '{"uuid":"some-query-uuid","params":{}}' | jq
```

Expect a 200 with the JSON result rows (or a 404 if the catalog has no
query for that uuid — that's a normal "not found" response from
query-service).

### Step 10 — Exercise the Query Services operations page

Navigate to `/admin/query-services` (sidebar **Query Services**).

- The new `myshop-users` instance appears in the table.
- **Status** column shows the container state (`running`).
- **Started** shows the timestamp (RFC 3339).
- Click **Logs** to see the query-service startup banner (you should see
  `query-service in INSTANCE mode — serving only dialect 'postgres'`).
- Click **Restart** to bounce the container; status flips to
  `Restarting (1)` for ~10s then back to `running`.

### Step 11 — Run the catalog UI

Navigate to `/admin/queries` (sidebar **Queries Catalog**). This is the
end-user-facing page, distinct from the operator-facing
`/admin/query-services`.

- The microservice picker shows all `kind=QUERY` rows. Pick `myshop-users`.
- The catalog table shows the queries bound to that microservice (filtered
  by your roles / `PUBLIC_END`).
- Click **Ejecutar** on a row to open the parameter drawer.
- Fill in any `:placeholder` params extracted from the SQL → click
  **Ejecutar** → the result table renders below.

## Failure modes & fixes

| Symptom | Likely cause | Fix |
|---|---|---|
| Toast: *"Microservicio creado"* (no QUERY suffix) | The sso-admin image is older than commit `7dd5959` and silently drops the new fields | `docker compose build sso-admin && docker compose up -d --no-deps sso-admin` |
| Drawer re-opens, kind flips back to REST | The form schema isn't validating the new fields; `setField("kind", ...)` didn't fire | Check the browser console; verify `admin-ui/src/schemas.ts` has the `microserviceFormSchema` with `kind: z.enum(["REST","QUERY"])` |
| HTTP 500 with `NoResourceFoundException: No static resource sso-admin/microservice/save` | Gateway image predates `d16f21b` and only has the legacy `StripPrefix=1` route | `docker compose build api-gateway && docker compose up -d --no-deps api-gateway` |
| HTTP 504 with `EUREKA_TIMEOUT` after 45s | The new query-service container fails to register with Eureka — usually because the autoconfig exclude is misconfigured (Boot 4 package moves), the `EnvironmentPostProcessor` `.imports` file is missing, or the resolver isn't prefixing `query-service-` | See [Boot 4 fixes memory](../../../../.claude/projects/-Users-apple-Documents-djromero-projects-sso-postgres/memory/spring-boot-4-package-moves.md) |
| Container stuck in `Restarting (1)` with `Failed to determine a suitable driver class` | query-service image has the old Boot-3 `spring.autoconfigure.exclude` paths that Boot 4 ignores | `docker compose build query-service-postgres && docker compose up -d --no-deps query-service-postgres` |
| Container registers as `SMOKE-X` (uppercased, no `query-service-` prefix) in Eureka | `InstanceNameResolver` didn't run | Verify `BOOT-INF/lib/META-INF/spring/org.springframework.boot.env.EnvironmentPostProcessor.imports` exists in the jar and contains `com.co.eurekatic.query.config.InstanceNameResolver` |
| `docker exec sso-provisioner curl --unix-socket /var/run/docker.sock ...` returns 403 | provisioner container doesn't have access to the socket | Verify `docker-compose.yml` has `volumes: - /var/run/docker.sock:/var/run/docker.sock` on the provisioner block; on colima the socket is mode 0600 owned by the host user, so the provisioner must run as root (see comment in compose) |

## Cleanup

```bash
# Remove leftover smoke containers
docker rm -f $(docker ps -a -q --filter name=query-service-smoke-) 2>/dev/null

# Remove the microservice row + its container
docker rm -f query-service-myshop-users  # stop the container first
# then delete the row from the UI (or via psql):
docker exec -i sso-postgres psql -U sso -d sso \
  -c "DELETE FROM MICROSERVICE WHERE SERVICEID='myshop-users';"
```