-- =============================================================================
-- V4 — MICROSERVICE columns for the dynamic query-service provisioner
-- (admin-ui "kind=QUERY" rows). Ported from
-- postgres/init/04-add-microservice-query-fields.sh.
--
--   KIND         — 'REST' (default) or 'QUERY' (docker-provisioned instances)
--   DIALECT      — postgres | oracle | sqlserver (NULL for REST)
--   JDBCURL      — connection string passed to the new container as QUERY_DS_URL
--   DBUSERNAME   — DB user
--   DBPASSWORD   — DB password (plaintext in v1 — prod encryption is a follow-up)
--   POOLSIZE     — HikariCP maximum-pool-size
--   INSTANCENAME — overrides the dialect-derived service id
-- =============================================================================

ALTER TABLE MICROSERVICE ADD COLUMN IF NOT EXISTS KIND VARCHAR(20) NOT NULL DEFAULT 'REST';
ALTER TABLE MICROSERVICE ADD COLUMN IF NOT EXISTS DIALECT VARCHAR(40);
ALTER TABLE MICROSERVICE ADD COLUMN IF NOT EXISTS JDBCURL VARCHAR(1000);
ALTER TABLE MICROSERVICE ADD COLUMN IF NOT EXISTS DBUSERNAME VARCHAR(120);
ALTER TABLE MICROSERVICE ADD COLUMN IF NOT EXISTS DBPASSWORD VARCHAR(500);
ALTER TABLE MICROSERVICE ADD COLUMN IF NOT EXISTS POOLSIZE INTEGER;
ALTER TABLE MICROSERVICE ADD COLUMN IF NOT EXISTS INSTANCENAME VARCHAR(120);

-- Partial unique index: instanceName is non-null only for QUERY rows;
-- REST rows can coexist freely.
CREATE UNIQUE INDEX IF NOT EXISTS uq_microservice_instancename
    ON MICROSERVICE(INSTANCENAME) WHERE INSTANCENAME IS NOT NULL;

-- Defensive backfill for rows inserted before the column existed.
UPDATE MICROSERVICE SET KIND = 'REST' WHERE KIND IS NULL;
