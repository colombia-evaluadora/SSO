-- ============================================================================
-- V392 — pigse.fn_est_soft_delete_bulk (POST /pigse/establecimientos/bulk-delete)
-- tiraba "column reference "pk_establecimiento" is ambiguous" (sqlState 42702)
-- para CUALQUIER llamada, dejando el borrado masivo de establecimientos
-- totalmente roto en producción. La función RETURNS TABLE(pk_establecimiento
-- ..., status ...) declara una columna de salida llamada pk_establecimiento,
-- que en PL/pgSQL se comporta como una variable del bloque; el UPDATE de más
-- abajo hacía "WHERE PK_ESTABLECIMIENTO = v_pk" sin calificar con la tabla,
-- así que Postgres no podía decidir si se refería a esa variable o a la
-- columna real de pigse.TESTABLECIMIENTO. El resto de la función (el
-- NOT EXISTS de arriba) ya usaba el alias "e." correctamente -- solo faltó
-- en este UPDATE.
-- ============================================================================

CREATE OR REPLACE FUNCTION pigse.fn_est_soft_delete_bulk(p_pk_usuario_solicitante bigint, p_pks bigint[])
 RETURNS TABLE(pk_establecimiento character varying, status character varying)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pigse', 'academico_test', 'public'
AS $function$
DECLARE
    v_pk BIGINT;
BEGIN
    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    FOREACH v_pk IN ARRAY COALESCE(p_pks, ARRAY[]::BIGINT[])
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO e WHERE e.PK_ESTABLECIMIENTO = v_pk AND e.ACTIVE = TRUE) THEN
            RETURN QUERY SELECT v_pk::VARCHAR, 'error:no_encontrado'::VARCHAR;
            CONTINUE;
        END IF;

        UPDATE pigse.TESTABLECIMIENTO e
           SET ACTIVE = FALSE, MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE e.PK_ESTABLECIMIENTO = v_pk;

        RETURN QUERY SELECT v_pk::VARCHAR, 'eliminado'::VARCHAR;
    END LOOP;
END;
$function$;

DO $$
DECLARE
    v_body TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_body
      FROM pg_proc WHERE proname = 'fn_est_soft_delete_bulk' AND pronamespace = 'pigse'::regnamespace;

    IF v_body NOT ILIKE '%UPDATE pigse.TESTABLECIMIENTO e%' THEN
        RAISE EXCEPTION 'V392: fn_est_soft_delete_bulk no quedo con el alias en el UPDATE';
    END IF;

    RAISE NOTICE 'V392 OK: pigse.fn_est_soft_delete_bulk ya no tiene la columna ambigua en el UPDATE.';
END $$;
