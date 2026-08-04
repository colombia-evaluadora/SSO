-- REPLICA IDENTITY FULL on every academico_test table so UPDATE/DELETE
-- events carry the complete before-image (required by the transformer chain).
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT schemaname, tablename
        FROM pg_tables
        WHERE schemaname = 'academico_test'
    LOOP
        EXECUTE format('ALTER TABLE %I.%I REPLICA IDENTITY FULL', r.schemaname, r.tablename);
    END LOOP;
END $$;
