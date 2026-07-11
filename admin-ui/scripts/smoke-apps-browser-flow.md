# Browser smoke flow — Apps admin end-to-end

Manual verification that the new admin-ui `Apps` page correctly creates an
`App`, binds/unbinds entities across all 4 families (roles, users, routes,
microservices), and deletes the app — wired through the gateway, sso-admin,
and Postgres.

## Pre-flight

1. **Stack is up.**
   ```bash
   docker ps --format 'table {{.Names}}\t{{.Status}}'
   ```
   Expect 7+ containers UP. The critical ones for this smoke are
   `sso-postgres`, `sso-auth-center`, `sso-admin`, `sso-api-gateway`. The
   `sso-admin` and `sso-api-gateway` containers often show `(unhealthy)` —
   that's the docker `HEALTHCHECK` artifact (Boot 4 / JDK 25 startup is
   slow), not a functional problem. If the gateway answers on
   `http://localhost:8080/login`, the smoke can run.

2. **Backend smoke is green.** Run the curl smoke first to confirm the
   data path end-to-end before clicking through the UI:
   ```bash
   bash admin-ui/scripts/smoke-apps.sh
   ```
   Expect `✅ PASS — App CRUD + 4 binding families work end-to-end`.
   23 / 23 checks should pass. If any check fails, the UI cannot fix it;
   debug the backend first.

3. **Browser is pointed at the gateway.**
   - URL: `http://localhost:8080/admin/apps`
   - Login: `admin` / `ChangeMe-Now-Please-123!`

## Flow

### Step 1 — Open the Apps page

Navigate to `/admin/apps` (sidebar entry **Apps**).

You should see a table listing existing apps. Each row shows:

- **Nombre** — the app's `name` (bold)
- **Descripción** — truncated to ~16 rem, full text on hover
- **Creado** — `createdDate` formatted with `toLocaleDateString()`
- **Bindings** — 4 small badges: `Roles · N`, `Users · N`, `Rutas · N`,
  `Micros · N` — one per family
- **Actions** — Editar / Eliminar buttons

The "+ Nueva app" button (top-right) opens the create drawer.

If you see "No se pudo cargar la lista. ¿sso-admin está UP?", the
gateway can't reach sso-admin — check `docker logs sso-admin | tail -50`
and the api-gateway route (`/api/sso-admin/**` with `StripPrefix=1`).

### Step 2 — Open the create drawer

Click **+ Nueva app**. The drawer slides in from the right with title
**Nueva app** and the **General** tab selected.

You'll see a `Form<AppFormValues>` with:

- `Nombre` — text input (required, max 255 chars, hint "Único en el sistema")
- `Descripción` — text input (max 500 chars)

The other 4 tabs (Roles, Usuarios, Rutas, Microservicios) are visible
but **disabled** with the hint:

> Guarda la app primero para habilitar la gestión de vinculaciones.

### Step 3 — Create an app

Fill in:

| Field       | Value                          |
|-------------|--------------------------------|
| Nombre      | `my-shop`                      |
| Descripción | `MyShop storefront (smoke)`    |

Click **Crear**. The drawer closes; a green toast appears:

> *"App creada"*

The new row appears in the table. Its bindings badges all show `· 0`.

Behind the scenes:
1. admin-ui `POST /api/sso-admin/app/save` with `{ name, description }`.
2. sso-admin `AppService.create` writes the row to `app` with a
   server-generated `created_date` (Postgres `DEFAULT CURRENT_TIMESTAMP`).
3. The `useCreateApp` mutation invalidates `appKeys.list()`, the table
   refetches, the new row renders.

### Step 4 — Edit the app, observe edit-keeps-open

Click **Editar** on the new row. The drawer slides in with title
**Editar app: my-shop** and the **General** tab selected.

The form is pre-filled with the values from step 3. Change the
description to `MyShop storefront (smoke v2)` and click **Guardar
cambios**.

- Green toast: *"App actualizada"*
- The drawer **stays open** (intentional — you can keep toggling
  bindings without re-opening).
- The `name` input is still visible.

### Step 5 — Bind a role (Roles tab)

Click the **Roles** tab. The drawer switches panels without closing
the drawer (it's all inside the same `<Tabs>`). You should see a list
of all roles from the database, each with a **Vincular** button (none
are bound yet — all show `checked: false`).

Click **Vincular** next to **ADMIN**. The button changes to
**Desvincular** (the binding POST returned 204 and the `checked` flag
flipped). The badge in the table at `/admin/apps` would now read
`Roles · 1` if you closed the drawer and looked — but you don't need
to close it: the list query is invalidated by `useBindAppRole`.

### Step 6 — Bind a user (Usuarios tab)

Click the **Usuarios** tab. Same pattern — every user has a Vincular
button. Bind one. Toast doesn't appear here (only CRUD submits toast;
binding toggles are silent because the row state IS the feedback).

### Step 7 — Bind a route (Rutas tab)

Click the **Rutas** tab. Each route shows `name` plus its `path` in
secondary text (slate-500). Bind one. The toggle works identically.

### Step 8 — Bind a microservice (Microservicios tab)

Click the **Microservicios** tab. Each row shows the `serviceId`
(mono font) plus a small `kind` badge — `QUERY` rows are violet,
`REST` rows are slate. Bind one.

### Step 9 — Verify the table badges

Close the drawer with the X. The row in the table should now show
all 4 counts > 0 (e.g. `Roles · 1 · Users · 1 · Rutas · 1 · Micros · 1`).

Behind the scenes: the drawer doesn't optimistically update the table;
it invalidates `appKeys.list()` after every binding toggle, so the
counts you see are the result of one fresh `GET /api/sso-admin/app/getApps`.

### Step 10 — Duplicate name returns 409

Click **+ Nueva app**. Type the same name (`my-shop`) and click
**Crear**.

- The drawer **stays open** (not closes-on-success).
- A red toast appears: *"DUPLICATE: …"* (the backend error envelope's
  `code` + `message`).
- The backend's `AppService.create` raises a `409 CONFLICT` via the
  `app.name UNIQUE` constraint. The `<Form>` component catches the
  error envelope and surfaces it.

This is the cross-app invariant: app names are unique system-wide.
Close the drawer with Cancelar.

### Step 11 — Delete the app

Click **Eliminar** on the `my-shop` row. A modal appears titled
**Eliminar app** with description:

> *"Se eliminará "my-shop" y todas sus asociaciones."*

Click **Eliminar** (the danger button, testid `app-confirm-delete`).

- Modal closes.
- Toast: *"App eliminada"*.
- Row disappears from the table.

Behind the scenes: `DELETE /api/sso-admin/app/{id}` returns 204. The
Postgres `ON DELETE CASCADE` on `role_app`, `app_users`, `app_route`,
`app_microservice` (defined in `06-create-app-tables.sh`) cleans up
all 4 binding tables automatically. The FKs on `ROUTE.id_app` and
`MICROSERVICE.id_app` are `ON DELETE SET NULL` (intentional — deleting
the app doesn't cascade to its routes/microservices, they survive as
orphans).

### Step 12 — Verify the cascade in Postgres

```bash
docker exec -i sso-postgres psql -U sso -d sso -t -A \
  -c "SELECT 'app:' || count(*) FROM app WHERE name = 'my-shop'
      UNION ALL SELECT 'role_app:' || count(*) FROM role_app WHERE id_role = 1;"
```

Expect both counts `0`. The app row is gone AND the binding rows that
referenced it are gone (cascade), so there are no orphans.

## Failure modes & fixes

| Symptom | Likely cause | Fix |
|---|---|---|
| Drawer opens but roles/users/routes/microservices tabs show "No hay X creados." and the database has rows | The checked-endpoint URL is wrong, or sso-admin image is older than commit `6f10483` | `docker compose build sso-admin && docker compose up -d --no-deps sso-admin` |
| "Editar" opens drawer but General tab shows empty `name` and `description` fields | `useApps` query is stale — the row in cache has no `description` (older backend image without the field) | Force-refresh the table (F5), confirm `/admin/app/getApps` returns the field |
| Click Vincular → row stays checked=false, button text doesn't flip | The `useBindApp{Entity}` mutation didn't invalidate the checked query, OR the backend returned a non-204 | Check the Network tab for the POST. Expect 204 with empty body. Check `admin-ui/src/hooks/useApps.ts` — the `onSuccess` should invalidate `appKeys.{entity}Checked(id)` and `appKeys.list()` |
| 409 on edit when changing the name to one that already exists in another app | The `name` UNIQUE constraint is enforced on PUT too (the validation in `AppService.update` checks cross-row uniqueness) | Pick a unique name, or delete the other app first. The toast will say `DUPLICATE`. |
| Edit drawer closes after "Guardar cambios" | Regression: someone flipped `setEditing(null)` into the update path | Compare `AppsListPage.handleSubmit` against the approved design — update branch should NOT call `setEditing(null)` |
| Delete confirm modal doesn't appear | The click hit a different button (e.g. the row's Eliminar vs the modal's Eliminar) | Inspect: the table's button has `data-testid="delete-{id}"`, the modal's has `data-testid="app-confirm-delete"`. Different. |
| App row gone from UI but `psql` still shows it | The DELETE 204 is async — TanStack Query hasn't refetched yet | Hard refresh (F5) — the `useDeleteApp` mutation invalidates `appKeys.list()` and refetches |
| Gateway returns 502 on `/api/sso-admin/app/**` | api-gateway route missing or `StripPrefix` wrong | See [gateway route memory](../../../../.claude/projects/-Users-apple-Documents-djromero-projects-sso-postgres/memory/gateway-api-sso-admin-route.md) — must be `StripPrefix=1`, NOT 2 |
| 401 Unauthorized after first POST | The JWT expired or wasn't sent on the binding calls | Check the Network tab for the `Authorization: Bearer …` header on every binding POST |

## Cleanup

The smoke doesn't leave behind any rows (step 11 deletes the app, and
Postgres CASCADE removes the M:N rows). If a test was interrupted
mid-flow, find orphans with:

```bash
docker exec -i sso-postgres psql -U sso -d sso -t -A \
  -c "SELECT id_app, name FROM app ORDER BY id_app DESC LIMIT 10;"
```

Delete the leftovers by id (or via the UI's Eliminar button):

```bash
docker exec -i sso-postgres psql -U sso -d sso \
  -c "DELETE FROM app WHERE name LIKE 'smoke-app-%' OR name = 'my-shop';"
```