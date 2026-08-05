-- Publication for the 147 academic tables (NOT FOR ALL TABLES — excludes
-- staging/benchmark tables from other containers).
-- Idempotent: drops existing publication if any, then re-creates with current set.
--
-- The replication slot (`cdc_slot`) is created by the
-- `cdc-pg-slot-init` docker-compose service AFTER this migration
-- succeeds, because `pg_create_logical_replication_slot` cannot run
-- inside a transaction that has performed writes (the CREATE
-- PUBLICATION above counts) — and Flyway OSS wraps every SQL
-- migration in a transaction. Splitting the slot out into its own
-- post-Flyway init step keeps Flyway happy and the order still
-- resolves to: publication ready → slot created → cdc-capture boots.

DROP PUBLICATION IF EXISTS cdc_pub;

-- Build comma-separated list of fully-qualified tables in academico_test
DO $$
DECLARE
    tlist text := '';
    r RECORD;
BEGIN
    FOR r IN
        SELECT schemaname, tablename
        FROM pg_tables
        WHERE schemaname = 'academico_test'
        ORDER BY tablename
    LOOP
        tlist := tlist || format('%I.%I,', r.schemaname, r.tablename);
    END LOOP;
    -- Strip trailing comma
    tlist := rtrim(tlist, ',');
    EXECUTE format('CREATE PUBLICATION cdc_pub FOR TABLE %s', tlist);
END $$;
