-- V311 - Parámetros de edad, capa 3 de 5: núcleos sin permisos.
-- Guardar es un upsert por grado o calendario; eliminar borra la fila.
-- Depende de: V308 (tablas), V310 (validaciones).

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_parametroedad_listar_interno()
RETURNS JSONB
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
        'grados', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'pkGrado', lv.PK_LISTA_VALOR,
                       'grado',   lv.NOMBRE,
                       'edad',    e.EDAD)
                   ORDER BY lv.ORDEN, lv.NOMBRE)
              FROM academico_test.TEDAD_RECOMENDADA_GRADO e
              JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = e.FK_TLV_GRADO
        ), '[]'::jsonb),
        'calendarios', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'pkCalendario', lv.PK_LISTA_VALOR,
                       'calendario',   lv.NOMBRE,
                       'mes',          c.MES,
                       'dia',          c.DIA)
                   ORDER BY lv.ORDEN, lv.NOMBRE)
              FROM academico_test.TFECHA_CORTE_CALENDARIO c
              JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = c.FK_TLV_CALENDARIO
        ), '[]'::jsonb));
$$;

COMMENT ON FUNCTION academico_test.fn_parametroedad_listar_interno()
    IS 'INTERNO: {grados:[{pkGrado, grado, edad}], calendarios:[{pkCalendario, calendario, mes, dia}]} en el orden de cada lista. Lo usa GET /parametros-edad.';

CREATE OR REPLACE FUNCTION academico_test.fn_parametroedad_grado_guardar_interno(
    p_pk_usuario   BIGINT,
    p_fk_tlv_grado BIGINT,
    p_edad         INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_parametroedad_validar_valor_lista(p_fk_tlv_grado, 'GRADOS', 'grado');
    PERFORM academico_test.fn_parametroedad_validar_edad(p_edad);

    INSERT INTO academico_test.TEDAD_RECOMENDADA_GRADO (FK_TLV_GRADO, EDAD, CREATED_BY)
    VALUES (p_fk_tlv_grado, p_edad, COALESCE(p_pk_usuario::VARCHAR, 'sistema'))
    ON CONFLICT (FK_TLV_GRADO) DO UPDATE
       SET EDAD        = EXCLUDED.EDAD,
           MODIFIED_BY = COALESCE(p_pk_usuario::VARCHAR, 'sistema'),
           MODIFIED_AT = CURRENT_TIMESTAMP;

    RETURN jsonb_build_object('pkGrado', p_fk_tlv_grado, 'edad', p_edad);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_parametroedad_grado_guardar_interno(BIGINT, BIGINT, INTEGER)
    IS 'INTERNO: crea o reemplaza la edad recomendada del grado (pk de la lista GRADOS). Errores: P0002 grado inexistente; 22023 edad fuera de 2-25.';

CREATE OR REPLACE FUNCTION academico_test.fn_parametroedad_calendario_guardar_interno(
    p_pk_usuario        BIGINT,
    p_fk_tlv_calendario BIGINT,
    p_mes               INTEGER,
    p_dia               INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_parametroedad_validar_valor_lista(p_fk_tlv_calendario, 'CALENDARIO', 'calendario');
    PERFORM academico_test.fn_parametroedad_validar_fecha_corte(p_mes, p_dia);

    INSERT INTO academico_test.TFECHA_CORTE_CALENDARIO (FK_TLV_CALENDARIO, MES, DIA, CREATED_BY)
    VALUES (p_fk_tlv_calendario, p_mes, p_dia, COALESCE(p_pk_usuario::VARCHAR, 'sistema'))
    ON CONFLICT (FK_TLV_CALENDARIO) DO UPDATE
       SET MES         = EXCLUDED.MES,
           DIA         = EXCLUDED.DIA,
           MODIFIED_BY = COALESCE(p_pk_usuario::VARCHAR, 'sistema'),
           MODIFIED_AT = CURRENT_TIMESTAMP;

    RETURN jsonb_build_object('pkCalendario', p_fk_tlv_calendario, 'mes', p_mes, 'dia', p_dia);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_parametroedad_calendario_guardar_interno(BIGINT, BIGINT, INTEGER, INTEGER)
    IS 'INTERNO: crea o reemplaza la fecha de corte del calendario (pk de la lista CALENDARIO). Errores: P0002 calendario inexistente; 22023 mes, día o 29 de febrero.';

CREATE OR REPLACE FUNCTION academico_test.fn_parametroedad_grado_eliminar_interno(p_fk_tlv_grado BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM academico_test.TEDAD_RECOMENDADA_GRADO WHERE FK_TLV_GRADO = p_fk_tlv_grado;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El grado % no tiene edad recomendada',
            academico_test.fn_listavalor_etiqueta(p_fk_tlv_grado)
            USING ERRCODE = 'P0002';
    END IF;
    RETURN jsonb_build_object('pkGrado', p_fk_tlv_grado);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_parametroedad_grado_eliminar_interno(BIGINT)
    IS 'INTERNO: quita la edad recomendada del grado; sus inscripciones y matrículas quedan Sin calcular. Errores: P0002 si el grado no tenía edad.';

CREATE OR REPLACE FUNCTION academico_test.fn_parametroedad_calendario_eliminar_interno(p_fk_tlv_calendario BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM academico_test.TFECHA_CORTE_CALENDARIO WHERE FK_TLV_CALENDARIO = p_fk_tlv_calendario;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El calendario % no tiene fecha de corte',
            academico_test.fn_listavalor_etiqueta(p_fk_tlv_calendario)
            USING ERRCODE = 'P0002';
    END IF;
    RETURN jsonb_build_object('pkCalendario', p_fk_tlv_calendario);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_parametroedad_calendario_eliminar_interno(BIGINT)
    IS 'INTERNO: quita la fecha de corte del calendario; sus inscripciones y matrículas quedan Sin calcular. Errores: P0002 si el calendario no tenía fecha de corte.';
