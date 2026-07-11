-- =============================================================================
-- V6 — APP + 4 M:N join tables (role_app, app_users, app_route,
-- app_microservice) + direct id_app FKs on ROUTE and MICROSERVICE.
-- Ported from postgres/init/06-create-app-tables.sh.
--
-- SKIP screens / reports: the legacy SSO_V2 APP_SCREEN / ROLE_SCREEN /
-- REPORT / REPORT_FILTER / ROLE_REPORT are intentionally omitted — the
-- modernized stack has no SCREEN entity nor REPORT table (low-code was
-- dropped; reports were reconceived as the dynamic Query/Write engine).
-- =============================================================================

-- APP — logical root grouping routes + microservices + users. Roles
-- bind to the app for broad access, or to a route/microservice for fine access.
CREATE TABLE IF NOT EXISTS app (
    id_app        BIGSERIAL    PRIMARY KEY,
    name          VARCHAR(255) NOT NULL UNIQUE,
    description   VARCHAR(500),
    created_date  TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_app_name ON app(name);

-- ROLE_APP — M:N between app and role (broad access: a role here sees
-- ALL routes of that app). Coexists with role_route (fine access).
CREATE TABLE IF NOT EXISTS role_app (
    id_app   BIGINT NOT NULL REFERENCES app(id_app)   ON DELETE CASCADE,
    id_role  BIGINT NOT NULL REFERENCES role(id_role) ON DELETE CASCADE,
    PRIMARY KEY (id_app, id_role)
);

CREATE INDEX IF NOT EXISTS idx_role_app_role ON role_app(id_role);

-- APP_USERS — M:N between app and users (explicit membership).
CREATE TABLE IF NOT EXISTS app_users (
    id_app   BIGINT NOT NULL REFERENCES app(id_app)    ON DELETE CASCADE,
    id_user  BIGINT NOT NULL REFERENCES users(id_user) ON DELETE CASCADE,
    PRIMARY KEY (id_app, id_user)
);

CREATE INDEX IF NOT EXISTS idx_app_users_user ON app_users(id_user);

-- APP_ROUTE — M:N between app and ROUTE (a route may appear in several
-- apps, independent of the ROUTE.id_app "primary app" FK).
CREATE TABLE IF NOT EXISTS app_route (
    id_app    BIGINT NOT NULL REFERENCES app(id_app)     ON DELETE CASCADE,
    id_route  BIGINT NOT NULL REFERENCES ROUTE(ID_ROUTE) ON DELETE CASCADE,
    PRIMARY KEY (id_app, id_route)
);

CREATE INDEX IF NOT EXISTS idx_app_route_route ON app_route(id_route);

-- APP_MICROSERVICE — M:N between app and MICROSERVICE (same rationale).
CREATE TABLE IF NOT EXISTS app_microservice (
    id_app          BIGINT NOT NULL REFERENCES app(id_app)                   ON DELETE CASCADE,
    id_microservice BIGINT NOT NULL REFERENCES MICROSERVICE(ID_MICROSERVICE) ON DELETE CASCADE,
    PRIMARY KEY (id_app, id_microservice)
);

CREATE INDEX IF NOT EXISTS idx_app_microservice_ms ON app_microservice(id_microservice);

-- Direct id_app FKs on existing tables. Nullable + ON DELETE SET NULL
-- (deleting the app orphans the route/microservice at app=NULL, which
-- is the expected behavior: they keep existing standalone).
ALTER TABLE ROUTE        ADD COLUMN IF NOT EXISTS id_app BIGINT REFERENCES app(id_app) ON DELETE SET NULL;
ALTER TABLE MICROSERVICE ADD COLUMN IF NOT EXISTS id_app BIGINT REFERENCES app(id_app) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_route_app        ON ROUTE(id_app);
CREATE INDEX IF NOT EXISTS idx_microservice_app ON MICROSERVICE(id_app);
