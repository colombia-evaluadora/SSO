-- =============================================================================
-- V5 — QUERY / ROLE_QUERY / WRITE_DEFINITION / ROLE_WRITE.
-- Ported from postgres/init/05-create-query-tables.sh.
--
-- Column names are the lowercase snake_case Postgres produces from
-- unquoted UPPER_CASE identifiers, which must match the JPA @Column /
-- @JoinColumn names verbatim or Hibernate's ddl-auto=validate rejects
-- them on sso-admin boot. MICROSERVICE's PK is `id_microservice`
-- (legacy), NOT `id` — referencing the wrong column fails validation.
-- =============================================================================

-- QUERY — catalog of read SQL templates, resolved by uuid via
-- sso-admin's GET /getQuery and executed by query-service.
CREATE TABLE IF NOT EXISTS QUERY (
    ID_QUERY        BIGSERIAL PRIMARY KEY,
    UUID            VARCHAR(64)  NOT NULL UNIQUE,
    QUERY           TEXT         NOT NULL,
    TYPE            VARCHAR(64),
    PUBLIC_END      BOOLEAN      NOT NULL DEFAULT FALSE,
    CAPTCHA         BOOLEAN      NOT NULL DEFAULT FALSE,
    DETAIL          TEXT,
    ACTION          TEXT,
    STYLE           TEXT,
    CREATEDDATE     TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
    -- Which query-service instance owns this query. NULL = "global".
    MICROSERVICE_ID BIGINT REFERENCES MICROSERVICE(ID_MICROSERVICE)
);

CREATE INDEX IF NOT EXISTS idx_query_microservice ON QUERY(MICROSERVICE_ID);

-- ROLE_QUERY — M:M join between QUERY and ROLE. A user with at least
-- one role in this set (OR PUBLIC_END=TRUE) may resolve the query.
CREATE TABLE IF NOT EXISTS ROLE_QUERY (
    QUERY_ID BIGINT NOT NULL REFERENCES QUERY(ID_QUERY) ON DELETE CASCADE,
    ROLE_ID  BIGINT NOT NULL REFERENCES ROLE(ID_ROLE)   ON DELETE CASCADE,
    PRIMARY KEY (QUERY_ID, ROLE_ID)
);

-- WRITE_DEFINITION — write-side counterpart of QUERY. Table + column
-- names live ONLY in this catalog row (never on the request body):
-- callers send a uuid + value map; the service validates keys against
-- COLUMNS, then parameter-binds values.
CREATE TABLE IF NOT EXISTS WRITE_DEFINITION (
    ID_WRITE_DEFINITION BIGSERIAL PRIMARY KEY,
    UUID                VARCHAR(64)  NOT NULL UNIQUE,
    WRITE_TYPE          VARCHAR(16)  NOT NULL,
    TABLE_NAME          VARCHAR(200) NOT NULL,
    COLUMNS             TEXT         NOT NULL,
    KEY_COLUMNS         TEXT,
    CREATEDDATE         TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
);

-- ROLE_WRITE — M:M join between WRITE_DEFINITION and ROLE.
CREATE TABLE IF NOT EXISTS ROLE_WRITE (
    WRITE_DEFINITION_ID BIGINT NOT NULL REFERENCES WRITE_DEFINITION(ID_WRITE_DEFINITION) ON DELETE CASCADE,
    ROLE_ID             BIGINT NOT NULL REFERENCES ROLE(ID_ROLE) ON DELETE CASCADE,
    PRIMARY KEY (WRITE_DEFINITION_ID, ROLE_ID)
);

-- Defensive backfill: bind orphan QUERY rows to the legacy canonical
-- `query-service-postgres` instance if it exists (no-op on a fresh DB).
UPDATE QUERY q
   SET MICROSERVICE_ID = (SELECT ID_MICROSERVICE FROM MICROSERVICE
                          WHERE KIND = 'QUERY' AND INSTANCENAME = 'postgres'
                          LIMIT 1)
 WHERE q.MICROSERVICE_ID IS NULL
   AND EXISTS (SELECT 1 FROM MICROSERVICE
                WHERE KIND = 'QUERY' AND INSTANCENAME = 'postgres');
