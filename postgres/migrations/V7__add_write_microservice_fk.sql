-- =============================================================================
-- V7 — MICROSERVICE_ID FK on WRITE_DEFINITION, mirroring the FK already
-- on QUERY (V5). Lets the admin-ui Writes Catalog offer a "pick a table
-- from the connected datasource" dropdown per backing instance.
-- Ported from postgres/init/07-add-write-microservice-fk.sh.
-- =============================================================================

ALTER TABLE WRITE_DEFINITION
    ADD COLUMN IF NOT EXISTS MICROSERVICE_ID BIGINT
        REFERENCES MICROSERVICE(ID_MICROSERVICE);

CREATE INDEX IF NOT EXISTS idx_write_definition_microservice
    ON WRITE_DEFINITION(MICROSERVICE_ID);

-- Defensive backfill: point existing orphan writes at the legacy
-- canonical `query-service-postgres` instance if it exists (no-op on
-- a fresh DB).
UPDATE WRITE_DEFINITION w
   SET MICROSERVICE_ID = (SELECT ID_MICROSERVICE FROM MICROSERVICE
                          WHERE KIND = 'QUERY' AND INSTANCENAME = 'postgres'
                          LIMIT 1)
 WHERE w.MICROSERVICE_ID IS NULL
   AND EXISTS (SELECT 1 FROM MICROSERVICE
                WHERE KIND = 'QUERY' AND INSTANCENAME = 'postgres');
