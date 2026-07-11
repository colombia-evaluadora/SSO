-- =============================================================================
-- V3 — sso-admin Phase 2: MICROSERVICE / ENDPOINT / ROUTE + join tables.
-- Ported from postgres/init/03-create-sso-admin-phase2-tables.sh.
--
-- Table-name convention: legacy UPPER_CASE singular names
-- (MICROSERVICE, ENDPOINT, ROUTE) are kept so an eventual legacy
-- co-existence phase uses the same identifiers.
-- =============================================================================

-- MICROSERVICE — a single downstream HTTP service the gateway can route to.
CREATE TABLE IF NOT EXISTS MICROSERVICE (
    ID_MICROSERVICE  BIGSERIAL    PRIMARY KEY,
    SERVICEID        VARCHAR(200) NOT NULL UNIQUE,
    DESCRIPTION      VARCHAR(500),
    REQUESTURI       VARCHAR(500),
    TARGETURIPATH    VARCHAR(500),
    TARGETURLHOST    VARCHAR(500),
    TARGETURLPORT    VARCHAR(10),
    CREATEDDATE      TIMESTAMP    NOT NULL DEFAULT now()
);

-- ENDPOINT — a single HTTP method+path inside a microservice. Uniqueness
-- on (PATH, METHOD, DESCRIPTION) is a real DB-level constraint so
-- concurrent inserts can't bypass it.
CREATE TABLE IF NOT EXISTS ENDPOINT (
    ID_ENDPOINT   BIGSERIAL    PRIMARY KEY,
    METHOD        VARCHAR(10)  NOT NULL,
    PATH          VARCHAR(500) NOT NULL,
    DESCRIPTION   VARCHAR(500),
    NUMBERPARAMS  INTEGER      NOT NULL DEFAULT 0,
    CONSTRAINT uq_endpoint_path_method_desc UNIQUE (PATH, METHOD, DESCRIPTION)
);

-- ROUTE — a navigable menu item. Self-referencing tree via IDPARENT
-- (NULL = root; the service layer normalizes legacy "0" to NULL on write).
CREATE TABLE IF NOT EXISTS ROUTE (
    ID_ROUTE   BIGSERIAL    PRIMARY KEY,
    NAME       VARCHAR(200) NOT NULL,
    ICON       VARCHAR(200),
    PATH       VARCHAR(500) NOT NULL,
    MENUORDER  INTEGER      NOT NULL DEFAULT 0,
    TYPE       VARCHAR(50),
    IDPARENT   BIGINT       REFERENCES ROUTE(ID_ROUTE) ON DELETE CASCADE
);

-- ENDPOINT_MICROSERVICE (M:N) — owning side: Endpoint.
CREATE TABLE IF NOT EXISTS ENDPOINT_MICROSERVICE (
    ENDPOINT_ID     BIGINT NOT NULL REFERENCES ENDPOINT(ID_ENDPOINT)         ON DELETE CASCADE,
    MICROSERVICE_ID BIGINT NOT NULL REFERENCES MICROSERVICE(ID_MICROSERVICE) ON DELETE CASCADE,
    PRIMARY KEY (ENDPOINT_ID, MICROSERVICE_ID)
);

-- ROLE_ENDPOINT (M:N) — gates which roles can invoke a given endpoint.
CREATE TABLE IF NOT EXISTS ROLE_ENDPOINT (
    ENDPOINT_ID BIGINT NOT NULL REFERENCES ENDPOINT(ID_ENDPOINT) ON DELETE CASCADE,
    ROLE_ID     BIGINT NOT NULL REFERENCES role(id_role)         ON DELETE CASCADE,
    PRIMARY KEY (ENDPOINT_ID, ROLE_ID)
);

-- ROLE_ROUTE (M:N) — gates which roles can see a given menu route.
CREATE TABLE IF NOT EXISTS ROLE_ROUTE (
    ROUTE_ID BIGINT NOT NULL REFERENCES ROUTE(ID_ROUTE) ON DELETE CASCADE,
    ROLE_ID  BIGINT NOT NULL REFERENCES role(id_role)   ON DELETE CASCADE,
    PRIMARY KEY (ROUTE_ID, ROLE_ID)
);

CREATE INDEX IF NOT EXISTS idx_microservice_serviceid ON MICROSERVICE(SERVICEID);
CREATE INDEX IF NOT EXISTS idx_endpoint_path          ON ENDPOINT(PATH);
CREATE INDEX IF NOT EXISTS idx_route_idparent         ON ROUTE(IDPARENT);
CREATE INDEX IF NOT EXISTS idx_route_name_path        ON ROUTE(NAME, PATH);
