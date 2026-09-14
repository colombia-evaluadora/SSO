-- ============================================================================
-- V397 — pigse.fn_est_buscar_por_pk (GET /pigse/establecimientos/:id) nunca
-- devolvia FK_TFUNCIONARIO_RECTOR/FK_TFUNCIONARIO_SECRETARIA, aunque la tabla
-- si las tiene seteadas. El frontend (use-establishment.ts) espera esas dos
-- claves para resolver el rector/secretaria vinculado (fetchLinkedFuncionario)
-- y solo se protege contra `pk === null` -- como la clave venia OMITIDA
-- (undefined), no null, el guard no la atajaba y terminaba armando
-- GET /pigse/funcionarios/undefined (400), lo que a su vez rompia la carga
-- completa de la pagina de editar establecimiento.
--
-- academico_test (CEVAL) si expone estas columnas en su equivalente; PIGSE
-- se quedo atras al adaptarse. Se agregan las dos columnas al RETURN QUERY
-- (requiere DROP porque cambia la firma OUT de la funcion).
-- ============================================================================

DROP FUNCTION IF EXISTS pigse.fn_est_buscar_por_pk(bigint, bigint);

CREATE OR REPLACE FUNCTION pigse.fn_est_buscar_por_pk(p_pk_usuario_solicitante bigint, p_pk_establecimiento bigint)
 RETURNS TABLE(pk_establecimiento bigint, codigo character varying, nombre character varying, nit character varying, fk_tmunicipio bigint, municipio_nombre character varying, fk_tpropiedad_juridica bigint, direccion character varying, telefono character varying, correo_electronico character varying, fk_tlista_valor_zona bigint, fk_testablecimiento_origen bigint, entes jsonb, created_by character varying, created_at timestamp without time zone, modified_by character varying, modified_at timestamp without time zone, fk_tfuncionario_rector bigint, fk_tfuncionario_secretaria bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pigse', 'academico_test', 'public'
AS $function$
DECLARE
    v_active BOOLEAN;
BEGIN
    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante, NULL) THEN
        RAISE EXCEPTION 'El usuario no tiene permiso para ver en el modulo ESTABLECIMIENTO'
            USING ERRCODE = '42501';
    END IF;

    SELECT e.ACTIVE INTO v_active
      FROM pigse.TESTABLECIMIENTO e
     WHERE e.PK_ESTABLECIMIENTO = p_pk_establecimiento;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el establecimiento solicitado (%)', p_pk_establecimiento
            USING ERRCODE = 'P0002';
    END IF;

    IF v_active = FALSE THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT e.PK_ESTABLECIMIENTO, e.CODIGO, e.NOMBRE, e.NIT,
           e.FK_TMUNICIPIO, m.NOMBRE, e.FK_TPROPIEDAD_JURIDICA,
           e.DIRECCION, e.TELEFONO, e.CORREO_ELECTRONICO,
           e.FK_TLISTA_VALOR_ZONA, e.FK_TESTABLECIMIENTO_ORIGEN,
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object('pkEnte', en.PK_ENTE, 'nombre', en.NOMBRE)
                                ORDER BY en.NOMBRE)
                 FROM pigse.TENTE_ESTABLECIMIENTO te
                 JOIN pigse.TENTE en ON en.PK_ENTE = te.FK_TENTE AND en.ACTIVE = TRUE
                WHERE te.FK_TESTABLECIMIENTO = e.PK_ESTABLECIMIENTO AND te.ACTIVE = TRUE
           ), '[]'::JSONB),
           e.CREATED_BY, e.CREATED_AT, e.MODIFIED_BY, e.MODIFIED_AT,
           e.FK_TFUNCIONARIO_RECTOR, e.FK_TFUNCIONARIO_SECRETARIA
      FROM pigse.TESTABLECIMIENTO e
      JOIN pigse.TMUNICIPIO m ON m.PK_TMUNICIPIO = e.FK_TMUNICIPIO
     WHERE e.PK_ESTABLECIMIENTO = p_pk_establecimiento;
END;
$function$;

DO $$
DECLARE
    v_body TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_body
      FROM pg_proc WHERE proname = 'fn_est_buscar_por_pk' AND pronamespace = 'pigse'::regnamespace;

    IF v_body NOT ILIKE '%FK_TFUNCIONARIO_RECTOR%' OR v_body NOT ILIKE '%FK_TFUNCIONARIO_SECRETARIA%' THEN
        RAISE EXCEPTION 'V397: fn_est_buscar_por_pk no quedo devolviendo rector/secretaria';
    END IF;

    RAISE NOTICE 'V397 OK: pigse.fn_est_buscar_por_pk ahora devuelve fk_tfuncionario_rector/secretaria.';
END $$;
