-- ===========================================================================
-- V283 - la auditoria deja de depender de que alguien se acuerde.
--        Backfill de lo que hoy no se audita + event trigger para que toda
--        tabla nueva de academico_test quede auditada al crearse.
--
-- QUE FALTA HOY
--   Auditar una tabla necesita TRES cosas, y hasta ahora cada una se ponia
--   por su lado:
--
--     1. trg_audit_ctx          -- emite el mensaje logico con actor/etiqueta
--     2. estar en cdc_pub        -- la publicacion que lee Debezium
--     3. REPLICA IDENTITY FULL   -- para que el evento traiga la fila ANTERIOR
--
--   V26 instalo el trigger recorriendo las tablas que existian entonces, y
--   V276 lo repuso en las trece que habian nacido despues. Pero la
--   publicacion nunca se completo: cdc_pub se creo en V24 y desde entonces
--   solo V88 le añadio una tabla (tsesion_web), a mano.
--
--   Resultado medido en produccion Y en pruebas -- identico en los dos:
--
--       162 tablas con trg_audit_ctx
--       148 en cdc_pub
--       --------------------------------
--       14 tablas con trigger que NO se auditan
--
--   Son las de V276 mas treferente_curricular_nivel: Planeador, Referente
--   curricular, Matricula y Documentos institucionales. Emiten su mensaje de
--   contexto, pero como no estan publicadas, Debezium nunca ve el cambio y a
--   ClickHouse no llega nada. Sin error y sin aviso, que es la peor forma de
--   fallar para una auditoria.
--
-- LO QUE V276 DEJO ESCRITO
--   "ESTO NO CIERRA EL AGUJERO A FUTURO. Una tabla creada despues de V276
--    volvera a nacer sin trigger. La solucion definitiva es un event trigger
--    sobre CREATE TABLE, pero eso cambia el comportamiento del esquema para
--    todas las ramas a la vez y merece decidirse aparte."
--
--   Esa decision se toma aqui. Sin el event trigger, cada tabla nueva vuelve
--   a empezar el ciclo -- alguien lo detecta meses despues y hace otra V276.
--
-- COMO FUNCIONA
--   fn_cdc_asegurar_auditoria(schema, tabla) deja una tabla lista en los tres
--   frentes y es idempotente: comprueba antes de tocar, asi que reaplicarla no
--   hace nada. Se usa en dos sitios:
--
--     * el backfill de abajo, que la aplica a todo academico_test;
--     * el event trigger trg_cdc_tabla_nueva, que la aplica a cada tabla que
--       se cree a partir de ahora.
--
-- POR QUE EL EVENT TRIGGER NO PUEDE FALLAR NUNCA
--   Un event trigger que lanza excepcion BLOQUEA el DDL que lo disparo: un
--   fallo aqui haria que ningun CREATE TABLE funcionase en la base, incluidas
--   las migraciones de Flyway. Por eso todo su cuerpo va envuelto en
--   EXCEPTION WHEN OTHERS que degrada a WARNING: si algo sale mal, la tabla se
--   crea igual y queda el aviso en el log. Preferimos una tabla sin auditar a
--   un esquema que no admite tablas nuevas.
--
-- SECURITY DEFINER
--   ALTER PUBLICATION exige ser dueño de la publicacion. El event trigger se
--   dispara con el usuario que ejecuta el CREATE TABLE, que no tiene por que
--   serlo, asi que la funcion va como SECURITY DEFINER con search_path fijado.
--
-- QUE SE EXCLUYE
--   * Tablas que no son ordinarias (vistas, particiones, temporales, UNLOGGED
--     de trabajo).
--   * Nombres que delatan respaldos o pruebas: %_bak%, %_backup%, %_tmp%,
--     %_temp%, %_old%. Un respaldo puntual no necesita auditarse ni debe
--     ensuciar la publicacion. Este mismo criterio habria dejado fuera a la
--     tabla de respaldo que motivo la revision.
--
-- REPLICA IDENTITY
--   Se fija FULL, que es lo que usan 147 de las 162 tablas del esquema y lo
--   que hace falta para que el evento traiga fila_old completa. Con DEFAULT
--   solo llegaria la PK y la auditoria perderia el "antes" de cada UPDATE.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. La pieza reutilizable: deja una tabla lista para auditarse.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_cdc_asegurar_auditoria(
    p_schema TEXT,
    p_tabla  TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_cambio BOOLEAN := FALSE;
    v_oid    OID;
BEGIN
    SELECT c.oid INTO v_oid
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = p_schema
       AND c.relname = p_tabla
       AND c.relkind = 'r'           -- solo tablas ordinarias
       AND c.relpersistence = 'p';   -- ni temporales ni unlogged

    IF v_oid IS NULL THEN
        RETURN FALSE;
    END IF;

    -- Respaldos y tablas de trabajo quedan fuera a proposito.
    IF p_tabla ILIKE '%\_bak%'    ESCAPE '\' OR p_tabla ILIKE '%\_backup%' ESCAPE '\'
    OR p_tabla ILIKE '%\_tmp%'    ESCAPE '\' OR p_tabla ILIKE '%\_temp%'   ESCAPE '\'
    OR p_tabla ILIKE '%\_old%'    ESCAPE '\' THEN
        RETURN FALSE;
    END IF;

    -- (a) trigger de contexto -- misma definicion que V26 / V276.
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger tg
         WHERE tg.tgrelid = v_oid AND NOT tg.tgisinternal AND tg.tgname = 'trg_audit_ctx'
    ) THEN
        EXECUTE format(
            'CREATE TRIGGER trg_audit_ctx BEFORE INSERT OR UPDATE OR DELETE ON %I.%I '
            'FOR EACH STATEMENT EXECUTE FUNCTION academico_test.fn_audit_ctx()',
            p_schema, p_tabla);
        v_cambio := TRUE;
    END IF;

    -- (b) REPLICA IDENTITY FULL -- sin esto el UPDATE llega sin fila_old.
    IF (SELECT c.relreplident FROM pg_class c WHERE c.oid = v_oid) <> 'f' THEN
        EXECUTE format('ALTER TABLE %I.%I REPLICA IDENTITY FULL', p_schema, p_tabla);
        v_cambio := TRUE;
    END IF;

    -- (c) publicacion que lee Debezium.
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
         WHERE pubname = 'cdc_pub' AND schemaname = p_schema AND tablename = p_tabla
    ) THEN
        EXECUTE format('ALTER PUBLICATION cdc_pub ADD TABLE %I.%I', p_schema, p_tabla);
        v_cambio := TRUE;
    END IF;

    RETURN v_cambio;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_cdc_asegurar_auditoria(TEXT, TEXT) IS
    'V283 - deja una tabla lista para auditarse: trg_audit_ctx + REPLICA IDENTITY FULL + cdc_pub. Idempotente. La usan el backfill de V283 y el event trigger trg_cdc_tabla_nueva.';


-- ---------------------------------------------------------------------------
-- 2. Backfill: todo academico_test al dia.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    r       RECORD;
    v_n     INT := 0;
BEGIN
    FOR r IN
        SELECT t.schemaname, t.tablename
          FROM pg_tables t
         WHERE t.schemaname = 'academico_test'
         ORDER BY t.tablename
    LOOP
        IF academico_test.fn_cdc_asegurar_auditoria(r.schemaname, r.tablename) THEN
            v_n := v_n + 1;
            RAISE NOTICE 'V283: auditoria completada en %.%', r.schemaname, r.tablename;
        END IF;
    END LOOP;
    RAISE NOTICE 'V283: tablas corregidas = % (0 = ya estaba todo cubierto)', v_n;
END $$;


-- ---------------------------------------------------------------------------
-- 3. Event trigger: las tablas nuevas nacen auditadas.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_cdc_evento_tabla_nueva()
RETURNS EVENT_TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    obj RECORD;
BEGIN
    FOR obj IN
        SELECT * FROM pg_event_trigger_ddl_commands()
         WHERE command_tag = 'CREATE TABLE'
           AND object_type = 'table'
    LOOP
        BEGIN
            IF split_part(obj.object_identity, '.', 1) = 'academico_test' THEN
                PERFORM academico_test.fn_cdc_asegurar_auditoria(
                    split_part(obj.object_identity, '.', 1),
                    split_part(obj.object_identity, '.', 2));
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- Nunca bloquear el DDL: una tabla sin auditar es un problema
            -- menor que un esquema que no admite tablas nuevas.
            RAISE WARNING 'V283: no se pudo activar la auditoria en % (%). La tabla se creo igual.',
                obj.object_identity, SQLERRM;
        END;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_cdc_evento_tabla_nueva() IS
    'V283 - event trigger: toda tabla nueva de academico_test queda con trg_audit_ctx, REPLICA IDENTITY FULL y dentro de cdc_pub. Degrada a WARNING ante cualquier fallo para no bloquear el CREATE TABLE.';

DROP EVENT TRIGGER IF EXISTS trg_cdc_tabla_nueva;
CREATE EVENT TRIGGER trg_cdc_tabla_nueva
    ON ddl_command_end
    WHEN TAG IN ('CREATE TABLE')
    EXECUTE FUNCTION academico_test.fn_cdc_evento_tabla_nueva();
