-- ===========================================================================
-- V39.2 -- Periodo de evaluacion: nucleos _interno
-- ===========================================================================
-- QUE HACE: crear/actualizar/eliminar/listar/detalle sin permisos, y el
-- estado automatico (Calificable dentro de las fechas, NO Calificable fuera).
-- Validan con V39.1 antes de escribir; el gate y la auditoria van en V39.3.
-- POR QUE AQUI: capa 2 del modulo (V39.1 / V39.2 / V39.3).
-- DEPENDE DE: V22, V39.1.
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_sincronizar_estado_interno(
    p_pk BIGINT DEFAULT NULL
)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_calificable    BIGINT;
    v_no_calificable BIGINT;
    v_n              INTEGER;
BEGIN
    SELECT max(PK_LISTA_VALOR) FILTER (WHERE VALOR = '1'),
           max(PK_LISTA_VALOR) FILTER (WHERE VALOR = '2')
      INTO v_calificable, v_no_calificable
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'ESTADOPERIODOEVALUACION';
    IF v_calificable IS NULL OR v_no_calificable IS NULL THEN
        RAISE WARNING 'Catalogo ESTADOPERIODOEVALUACION sin VALOR 1/2; no se sincroniza el estado';
        RETURN 0;
    END IF;

    -- Las fechas solo alternan Calificable/NO Calificable. Los otros estados
    -- (p. ej. En Recuperaciones, que habilita refuerzos) los pone el usuario y se respetan.
    UPDATE academico_test.TPERIODO_EVALUACION
       SET FK_TLV_ESTADO = CASE WHEN CURRENT_DATE BETWEEN FECHA_INICIO AND FECHA_FIN
                                THEN v_calificable ELSE v_no_calificable END
     WHERE ACTIVE = TRUE
       AND (p_pk IS NULL OR PK_TPERIODO_EVALUACION = p_pk)
       AND FK_TLV_ESTADO IN (v_calificable, v_no_calificable)
       AND FK_TLV_ESTADO <> CASE WHEN CURRENT_DATE BETWEEN FECHA_INICIO AND FECHA_FIN
                                 THEN v_calificable ELSE v_no_calificable END;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_eval_sincronizar_estado_interno(BIGINT)
    IS 'INTERNO: pone Calificable si hoy esta entre FECHA_INICIO y FECHA_FIN y NO Calificable si no; otros estados (En Recuperaciones...) no se tocan. p_pk NULL = todos. La usan fn_periodo_eval_crear_interno/_actualizar_interno y el job diario periodo-eval-estado. Devuelve filas cambiadas.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_crear_interno(
    p_fk_periodo   BIGINT,
    p_codigo       VARCHAR,
    p_nombre       VARCHAR,
    p_abreviacion  VARCHAR,
    p_fecha_inicio DATE,
    p_fecha_fin    DATE,
    p_fk_estado    BIGINT,
    p_porcentaje   NUMERIC,
    p_audit        VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT;
BEGIN
    PERFORM academico_test.fn_periodo_eval_validar_campos(p_fk_periodo, p_codigo, p_nombre, p_abreviacion,
        p_fecha_inicio, p_fecha_fin, p_fk_estado);
    PERFORM academico_test.fn_periodo_eval_validar_fechas(p_fecha_inicio, p_fecha_fin);
    PERFORM academico_test.fn_periodo_eval_validar(p_fk_periodo, p_fecha_inicio, p_fecha_fin, p_porcentaje,
        p_codigo, p_nombre, p_abreviacion, NULL);

    INSERT INTO academico_test.TPERIODO_EVALUACION
        (CODIGO, NOMBRE, ABREVIACION, FECHA_INICIO, FECHA_FIN, FK_TLV_ESTADO,
         FK_TPERIODO_ACADEMICO, PORCENTAJE, CREATED_BY)
    VALUES (p_codigo, p_nombre, p_abreviacion, p_fecha_inicio, p_fecha_fin, p_fk_estado,
            p_fk_periodo, p_porcentaje, p_audit)
    RETURNING PK_TPERIODO_EVALUACION INTO v_id;
    PERFORM academico_test.fn_periodo_eval_sincronizar_estado_interno(v_id);
    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_eval_crear_interno(BIGINT, VARCHAR, VARCHAR, VARCHAR, DATE, DATE, BIGINT, NUMERIC, VARCHAR)
    IS 'INTERNO: valida e inserta un periodo de evaluacion y fija su estado por fechas. Lo usa fn_periodo_eval_crear.';

-- Los NULL conservan el valor actual.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_actualizar_interno(
    p_pk           BIGINT,
    p_codigo       VARCHAR,
    p_nombre       VARCHAR,
    p_abreviacion  VARCHAR,
    p_fecha_inicio DATE,
    p_fecha_fin    DATE,
    p_fk_estado    BIGINT,
    p_porcentaje   NUMERIC,
    p_audit        VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    r     academico_test.TPERIODO_EVALUACION;
    v_ini DATE;
    v_fin DATE;
    v_pct NUMERIC;
BEGIN
    SELECT * INTO r FROM academico_test.TPERIODO_EVALUACION WHERE PK_TPERIODO_EVALUACION = p_pk;
    v_ini := COALESCE(p_fecha_inicio, r.FECHA_INICIO);
    v_fin := COALESCE(p_fecha_fin, r.FECHA_FIN);
    v_pct := COALESCE(p_porcentaje, r.PORCENTAJE);
    PERFORM academico_test.fn_periodo_eval_validar_fechas(v_ini, v_fin);
    PERFORM academico_test.fn_periodo_eval_validar(r.FK_TPERIODO_ACADEMICO, v_ini, v_fin, v_pct,
        COALESCE(p_codigo, r.CODIGO), COALESCE(p_nombre, r.NOMBRE), COALESCE(p_abreviacion, r.ABREVIACION), p_pk);

    UPDATE academico_test.TPERIODO_EVALUACION SET
        CODIGO = COALESCE(p_codigo, CODIGO), NOMBRE = COALESCE(p_nombre, NOMBRE),
        ABREVIACION = COALESCE(p_abreviacion, ABREVIACION),
        FECHA_INICIO = v_ini, FECHA_FIN = v_fin,
        FK_TLV_ESTADO = COALESCE(p_fk_estado, FK_TLV_ESTADO), PORCENTAJE = v_pct,
        MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TPERIODO_EVALUACION = p_pk;
    PERFORM academico_test.fn_periodo_eval_sincronizar_estado_interno(p_pk);
    RETURN p_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_eval_actualizar_interno(BIGINT, VARCHAR, VARCHAR, VARCHAR, DATE, DATE, BIGINT, NUMERIC, VARCHAR)
    IS 'INTERNO: valida y actualiza un periodo de evaluacion existente y activo, y recalcula su estado por fechas. Lo usa fn_periodo_eval_actualizar.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_eliminar_interno(p_pk BIGINT, p_audit VARCHAR)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_eval_validar_sin_calificaciones(p_pk);

    UPDATE academico_test.TPERIODO_EVALUACION
       SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TPERIODO_EVALUACION = p_pk AND ACTIVE = TRUE
    RETURNING NOMBRE INTO v_nombre;
    IF NOT FOUND THEN
        SELECT NOMBRE INTO v_nombre
          FROM academico_test.TPERIODO_EVALUACION WHERE PK_TPERIODO_EVALUACION = p_pk;
        RAISE EXCEPTION 'El periodo de evaluacion "%" ya se encuentra inactivo', COALESCE(v_nombre, p_pk::TEXT)
            USING ERRCODE = 'P0002';
    END IF;
    RETURN p_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_eval_eliminar_interno(BIGINT, VARCHAR)
    IS 'INTERNO: baja logica; 23503 si tiene calificaciones, P0002 si ya estaba inactivo. Lo usa fn_periodo_eval_soft_delete.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_listar_interno(
    p_fk_periodo BIGINT,
    p_filtro     TEXT DEFAULT NULL,
    p_page_index INT  DEFAULT 0,
    p_page_size  INT  DEFAULT 10,
    p_sort_by    TEXT DEFAULT NULL,
    p_sort_dir   TEXT DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT, codigo VARCHAR, nombre VARCHAR, abreviacion VARCHAR,
    start_date DATE, end_date DATE, peso NUMERIC, status_id BIGINT, estado VARCHAR, estado_name VARCHAR,
    academic_period_id BIGINT, sede_id BIGINT, sede_name VARCHAR, total_count BIGINT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'codigo'      THEN 'pe.CODIGO'
        WHEN 'nombre'      THEN 'pe.NOMBRE'
        WHEN 'abreviacion' THEN 'pe.ABREVIACION'
        WHEN 'startdate'   THEN 'pe.FECHA_INICIO'
        WHEN 'enddate'     THEN 'pe.FECHA_FIN'
        WHEN 'peso'        THEN 'pe.PORCENTAJE'
        WHEN 'estado'      THEN 'est.VALOR'
        ELSE 'pe.FECHA_INICIO'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'desc' THEN 'DESC' ELSE 'ASC' END;

    -- p_page_size 0/NULL = sin limite (lo usa el reporte).
    RETURN QUERY EXECUTE format($q$
        SELECT pe.PK_TPERIODO_EVALUACION, pe.CODIGO, pe.NOMBRE, pe.ABREVIACION,
               pe.FECHA_INICIO, pe.FECHA_FIN, pe.PORCENTAJE, pe.FK_TLV_ESTADO, est.VALOR, est.NOMBRE,
               pe.FK_TPERIODO_ACADEMICO, s.PK_TSEDE, s.NOMBRE,
               count(*) OVER()::BIGINT
          FROM academico_test.TPERIODO_EVALUACION pe
          JOIN academico_test.TLISTA_VALOR est ON est.PK_LISTA_VALOR = pe.FK_TLV_ESTADO
          JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = pe.FK_TPERIODO_ACADEMICO
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
         WHERE pe.FK_TPERIODO_ACADEMICO = $1 AND pe.ACTIVE = TRUE
           AND ($2 IS NULL OR pe.NOMBRE ILIKE '%%' || $2 || '%%' OR pe.CODIGO ILIKE '%%' || $2 || '%%')
         ORDER BY %s %s, pe.PK_TPERIODO_EVALUACION DESC
         LIMIT NULLIF($4, 0)
        OFFSET COALESCE($3, 0) * COALESCE(NULLIF($4, 0), 0)
    $q$, v_col, v_dir)
    USING p_fk_periodo, NULLIF(TRIM(p_filtro),''), p_page_index, p_page_size;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_eval_listar_interno(BIGINT, TEXT, INT, INT, TEXT, TEXT)
    IS 'INTERNO: periodos de evaluacion activos de un periodo academico, paginados y ordenados, sin alcance. Lo usa fn_periodo_eval_listar (pantalla y reporte).';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_detalle_interno(p_pk BIGINT)
RETURNS TABLE (
    id BIGINT, codigo VARCHAR, nombre VARCHAR, abreviacion VARCHAR,
    start_date DATE, end_date DATE, peso NUMERIC, status_id BIGINT, estado VARCHAR, estado_name VARCHAR,
    academic_period_id BIGINT
)
LANGUAGE sql STABLE AS $$
    SELECT pe.PK_TPERIODO_EVALUACION, pe.CODIGO, pe.NOMBRE, pe.ABREVIACION,
           pe.FECHA_INICIO, pe.FECHA_FIN, pe.PORCENTAJE, pe.FK_TLV_ESTADO, est.VALOR, est.NOMBRE,
           pe.FK_TPERIODO_ACADEMICO
      FROM academico_test.TPERIODO_EVALUACION pe
      JOIN academico_test.TLISTA_VALOR est ON est.PK_LISTA_VALOR = pe.FK_TLV_ESTADO
     WHERE pe.PK_TPERIODO_EVALUACION = p_pk AND pe.ACTIVE = TRUE;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_eval_detalle_interno(BIGINT)
    IS 'INTERNO: un periodo de evaluacion activo, sin alcance. Lo usa fn_periodo_eval_detalle.';
