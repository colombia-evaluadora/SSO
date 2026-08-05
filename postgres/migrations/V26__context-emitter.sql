-- Function: emit a pg_logical_emit_message('audit_ctx', ...) per transaction
-- so the cdc-worker receives the session context alongside row-change events.
-- Unchanged from spec §4.3 of the original design.
CREATE OR REPLACE FUNCTION academico_test.fn_audit_ctx()
RETURNS TRIGGER AS $$
DECLARE
    v_ctx  json;
    v_etiq TEXT;
BEGIN
    v_ctx  := NULLIF(current_setting('app.contexto', true), '')::json;
    v_etiq := LEFT(NULLIF(current_setting('app.etiqueta', true), ''), 200);

    PERFORM pg_logical_emit_message(
        true,
        'audit_ctx',
        json_build_object(
            'tabla',      TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
            'op',         LEFT(TG_OP, 1),
            'app_user',   NULLIF(current_setting('app.user_id', true), ''),
            'db_user',    session_user,
            'sesion_id',  v_ctx ->> 'sesion_id',
            'familia',    v_ctx ->> 'familia',
            'request_id', LEFT(NULLIF(current_setting('app.request_id', true), ''), 100),
            'etiqueta',   v_etiq,
            'contexto',   v_ctx
        )::text
    );
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Install BEFORE STATEMENT trigger on every academico_test table.
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT schemaname, tablename
        FROM pg_tables
        WHERE schemaname = 'academico_test'
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_audit_ctx BEFORE INSERT OR UPDATE OR DELETE ON %I.%I
             FOR EACH STATEMENT EXECUTE FUNCTION academico_test.fn_audit_ctx()',
            r.schemaname, r.tablename
        );
    END LOOP;
END $$;