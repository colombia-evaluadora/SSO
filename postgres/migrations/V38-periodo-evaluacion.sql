-- ===========================================================================
-- Periodo de Evaluacion — funciones consolidadas (ultima version)
-- Generado: 2026-09-04
--
-- Documento de referencia de SOLO LECTURA. NO ejecutar. NO es una migracion
-- Flyway y NO debe copiarse a postgres/migrations/. Consolida, para cada
-- funcion del modulo, el bloque CREATE OR REPLACE tal como quedo en la
-- migracion mas reciente que lo redefine (las funciones se reescriben con
-- CREATE OR REPLACE FUNCTION en migraciones posteriores; este archivo evita
-- tener que rastrear cual version quedo vigente).
--
-- Migraciones fuente consultadas:
--   - V38__evaluation_period_module.sql
--   - V101__periodo_evaluacion_mensajes_error_con_nombre.sql
--   - V192__fn_periodo_eval_listar_expone_sede.sql
-- ===========================================================================

-- Fuente: V101__periodo_evaluacion_mensajes_error_con_nombre.sql
SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_validar(
    p_fk_periodo bigint,
    p_fecha_inicio date,
    p_fecha_fin date,
    p_porcentaje numeric,
    p_codigo character varying DEFAULT NULL::character varying,
    p_nombre character varying DEFAULT NULL::character varying,
    p_abreviacion character varying DEFAULT NULL::character varying,
    p_pk_excluir bigint DEFAULT NULL::bigint
)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_pi DATE; v_pf DATE; v_suma NUMERIC;
    v_nombre_periodo_academico VARCHAR(130);
BEGIN
    SELECT FECHA_INICIO, FECHA_FIN INTO v_pi, v_pf
      FROM academico_test.TPERIODO_ACADEMICO
     WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo AND ACTIVE = TRUE;
    IF v_pi IS NULL THEN
        SELECT NOMBRE INTO v_nombre_periodo_academico
          FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo;
        IF v_nombre_periodo_academico IS NOT NULL THEN
            RAISE EXCEPTION 'El periodo academico "%" esta inactivo', v_nombre_periodo_academico
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El periodo academico indicado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
    IF p_porcentaje IS NOT NULL AND p_porcentaje < 0 THEN
        RAISE EXCEPTION 'El porcentaje (%) no puede ser negativo', p_porcentaje USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_codigo),'') IS NOT NULL AND EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.FK_TPERIODO_ACADEMICO = p_fk_periodo AND pe.ACTIVE = TRUE
           AND pe.PK_TPERIODO_EVALUACION <> COALESCE(p_pk_excluir, -1)
           AND UPPER(TRIM(pe.CODIGO)) = UPPER(TRIM(p_codigo))
    ) THEN
        RAISE EXCEPTION 'Ya existe un periodo de evaluacion con el codigo % en este periodo academico', p_codigo
            USING ERRCODE = '23505';
    END IF;
    IF NULLIF(TRIM(p_nombre),'') IS NOT NULL AND EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.FK_TPERIODO_ACADEMICO = p_fk_periodo AND pe.ACTIVE = TRUE
           AND pe.PK_TPERIODO_EVALUACION <> COALESCE(p_pk_excluir, -1)
           AND UPPER(TRIM(pe.NOMBRE)) = UPPER(TRIM(p_nombre))
    ) THEN
        RAISE EXCEPTION 'Ya existe un periodo de evaluacion con el nombre % en este periodo academico', p_nombre
            USING ERRCODE = '23505';
    END IF;
    IF NULLIF(TRIM(p_abreviacion),'') IS NOT NULL AND EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.FK_TPERIODO_ACADEMICO = p_fk_periodo AND pe.ACTIVE = TRUE
           AND pe.PK_TPERIODO_EVALUACION <> COALESCE(p_pk_excluir, -1)
           AND UPPER(TRIM(pe.ABREVIACION)) = UPPER(TRIM(p_abreviacion))
    ) THEN
        RAISE EXCEPTION 'Ya existe un periodo de evaluacion con la abreviacion % en este periodo academico', p_abreviacion
            USING ERRCODE = '23505';
    END IF;
    IF p_fecha_inicio < v_pi OR p_fecha_fin > v_pf THEN
        RAISE EXCEPTION 'El periodo de evaluacion (% a %) debe estar dentro del periodo academico (% a %)',
            p_fecha_inicio, p_fecha_fin, v_pi, v_pf USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_EVALUACION pe
         WHERE pe.FK_TPERIODO_ACADEMICO = p_fk_periodo AND pe.ACTIVE = TRUE
           AND pe.PK_TPERIODO_EVALUACION <> COALESCE(p_pk_excluir, -1)
           AND p_fecha_inicio <= pe.FECHA_FIN AND p_fecha_fin >= pe.FECHA_INICIO
    ) THEN
        RAISE EXCEPTION 'El periodo de evaluacion se solapa con otro existente' USING ERRCODE = '22023';
    END IF;
    SELECT COALESCE(SUM(pe.PORCENTAJE), 0) INTO v_suma
      FROM academico_test.TPERIODO_EVALUACION pe
     WHERE pe.FK_TPERIODO_ACADEMICO = p_fk_periodo AND pe.ACTIVE = TRUE
       AND pe.PK_TPERIODO_EVALUACION <> COALESCE(p_pk_excluir, -1);
    IF v_suma + COALESCE(p_porcentaje, 0) > 100 THEN
        RAISE EXCEPTION 'La suma de pesos (% + %) supera el 100%%', v_suma, COALESCE(p_porcentaje, 0)
            USING ERRCODE = '22023';
    END IF;
END;
$function$;

-- Fuente: V38__evaluation_period_module.sql
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_crear(
    p_fk_periodo     BIGINT,
    p_codigo         VARCHAR(30),
    p_nombre         VARCHAR(130),
    p_abreviacion    VARCHAR(30),
    p_fecha_inicio   DATE,
    p_fecha_fin      DATE,
    p_fk_estado      BIGINT,
    p_porcentaje     NUMERIC DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    -- CU-86e2w4xdt: capability por el menu PERIODOS_ACADEMICOS + scope. El
    -- periodo de evaluacion no tiene sede ni jornada propias: las HEREDA de
    -- su TPERIODO_ACADEMICO padre.
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PERIODOS_ACADEMICOS', 'CREAR',
        academico_test.fn_periodo_establecimiento(p_fk_periodo),
        academico_test.fn_periodo_sede(p_fk_periodo),
        academico_test.fn_periodo_jornada(p_fk_periodo));
    IF p_fk_periodo IS NULL OR NULLIF(TRIM(p_codigo),'') IS NULL OR NULLIF(TRIM(p_nombre),'') IS NULL
       OR NULLIF(TRIM(p_abreviacion),'') IS NULL OR p_fecha_inicio IS NULL OR p_fecha_fin IS NULL
       OR p_fk_estado IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios del periodo de evaluacion' USING ERRCODE = '22023';
    END IF;
    IF p_fecha_fin <= p_fecha_inicio THEN
        RAISE EXCEPTION 'La fecha fin debe ser posterior a la fecha inicio' USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_periodo_eval_validar(p_fk_periodo, p_fecha_inicio, p_fecha_fin, p_porcentaje, p_codigo, p_nombre, p_abreviacion, NULL);

    INSERT INTO academico_test.TPERIODO_EVALUACION
        (CODIGO, NOMBRE, ABREVIACION, FECHA_INICIO, FECHA_FIN, FK_TLV_ESTADO,
         FK_TPERIODO_ACADEMICO, PORCENTAJE, CREATED_BY)
    VALUES (p_codigo, p_nombre, p_abreviacion, p_fecha_inicio, p_fecha_fin, p_fk_estado,
            p_fk_periodo, p_porcentaje, v_audit)
    RETURNING PK_TPERIODO_EVALUACION INTO v_id;
    RETURN v_id;
END;
$$;

-- Fuente: V101__periodo_evaluacion_mensajes_error_con_nombre.sql
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_actualizar(
    p_pk bigint,
    p_codigo character varying DEFAULT NULL::character varying,
    p_nombre character varying DEFAULT NULL::character varying,
    p_abreviacion character varying DEFAULT NULL::character varying,
    p_fecha_inicio date DEFAULT NULL::date,
    p_fecha_fin date DEFAULT NULL::date,
    p_fk_estado bigint DEFAULT NULL::bigint,
    p_porcentaje numeric DEFAULT NULL::numeric,
    p_pk_usuario_solicitante bigint DEFAULT NULL::bigint
)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    r academico_test.TPERIODO_EVALUACION;
    v_ini DATE; v_fin DATE; v_pct NUMERIC; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_establecimiento_id BIGINT;
BEGIN
    -- Autorizacion (CU-86e2w4xdt): capability fail-fast; scope abajo con la
    -- sede/jornada del periodo academico padre.
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, NULL, NULL, NULL, 'EDITAR');
    SELECT * INTO r FROM academico_test.TPERIODO_EVALUACION WHERE PK_TPERIODO_EVALUACION = p_pk;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el periodo de evaluacion indicado' USING ERRCODE = 'P0002';
    END IF;
    IF r.ACTIVE = FALSE THEN
        RAISE EXCEPTION 'El periodo de evaluacion "%" esta inactivo; no se puede actualizar', r.NOMBRE
            USING ERRCODE = '22023';
    END IF;
    -- Gate fino (CU-86e2w4xdt): capability + scope (EE, sede, jornada) del periodo academico padre.
    SELECT s.FK_TESTABLECIMIENTO INTO v_establecimiento_id
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE pa.PK_TPERIODO_ACADEMICO = r.FK_TPERIODO_ACADEMICO;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_establecimiento_id,
        academico_test.fn_periodo_sede(r.FK_TPERIODO_ACADEMICO),
        academico_test.fn_periodo_jornada(r.FK_TPERIODO_ACADEMICO), 'EDITAR');
    v_ini := COALESCE(p_fecha_inicio, r.FECHA_INICIO);
    v_fin := COALESCE(p_fecha_fin, r.FECHA_FIN);
    v_pct := COALESCE(p_porcentaje, r.PORCENTAJE);
    IF v_fin <= v_ini THEN
        RAISE EXCEPTION 'La fecha fin debe ser posterior a la fecha inicio' USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_periodo_eval_validar(r.FK_TPERIODO_ACADEMICO, v_ini, v_fin, v_pct,
        COALESCE(p_codigo, r.CODIGO), COALESCE(p_nombre, r.NOMBRE), COALESCE(p_abreviacion, r.ABREVIACION), p_pk);

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización del periodo de evaluación %s', COALESCE(p_nombre, r.NOMBRE)), v_establecimiento_id);

    UPDATE academico_test.TPERIODO_EVALUACION SET
        CODIGO = COALESCE(p_codigo, CODIGO), NOMBRE = COALESCE(p_nombre, NOMBRE),
        ABREVIACION = COALESCE(p_abreviacion, ABREVIACION),
        FECHA_INICIO = v_ini, FECHA_FIN = v_fin,
        FK_TLV_ESTADO = COALESCE(p_fk_estado, FK_TLV_ESTADO), PORCENTAJE = v_pct,
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TPERIODO_EVALUACION = p_pk;
    RETURN p_pk;
END;
$function$;

-- Fuente: V101__periodo_evaluacion_mensajes_error_con_nombre.sql
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_soft_delete(
    p_pk bigint,
    p_pk_usuario_solicitante bigint
)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR; v_est BIGINT;
    v_nombre_periodo_eval VARCHAR(130);
    v_sede_id    BIGINT;
    v_jornada_id BIGINT;
BEGIN
    -- Autorizacion (CU-86e2w4xdt): capability fail-fast.
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, NULL, NULL, NULL, 'ELIMINAR');
    -- Gate fino (CU-86e2w4xdt): capability + scope (EE, sede, jornada) del periodo academico padre.
    -- Se trae tambien el NOMBRE aqui (antes solo se leia en la rama de error)
    -- porque la etiqueta de auditoria lo necesita en el camino feliz.
    SELECT s.FK_TESTABLECIMIENTO, pa.FK_TSEDE, pa.FK_TLV_JORNADA, pe.NOMBRE
      INTO v_est, v_sede_id, v_jornada_id, v_nombre_periodo_eval
      FROM academico_test.TPERIODO_EVALUACION pe
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = pe.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE pe.PK_TPERIODO_EVALUACION = p_pk;
    IF v_est IS NOT NULL THEN
        PERFORM academico_test.fn_periodo_gate_escritura(
            p_pk_usuario_solicitante, v_est, v_sede_id, v_jornada_id, 'ELIMINAR');
    END IF;
    -- Bloqueo: existen calificaciones (notas) registradas contra este periodo de
    -- evaluacion. Protege informacion historica (TAREA_NOTA/TASIGNATURA_NOTA no
    -- dependen de que la matricula siga activa).
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA_NOTA an
         WHERE an.FK_TPERIODO_EVALUACION = p_pk AND an.ACTIVE = TRUE
    ) OR EXISTS (
        SELECT 1 FROM academico_test.TAREA_NOTA tn
         WHERE tn.FK_TPERIODO_EVALUACION = p_pk AND tn.ACTIVE = TRUE
    ) THEN
        SELECT NOMBRE INTO v_nombre_periodo_eval
          FROM academico_test.TPERIODO_EVALUACION WHERE PK_TPERIODO_EVALUACION = p_pk;
        IF v_nombre_periodo_eval IS NOT NULL THEN
            RAISE EXCEPTION 'No se puede eliminar el periodo de evaluacion "%": existen calificaciones registradas',
                v_nombre_periodo_eval USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'No se puede eliminar el periodo de evaluacion indicado: existen calificaciones registradas'
                USING ERRCODE = '23503';
        END IF;
    END IF;

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación del periodo de evaluación %s', v_nombre_periodo_eval), v_est);

    UPDATE academico_test.TPERIODO_EVALUACION
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TPERIODO_EVALUACION = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        SELECT NOMBRE INTO v_nombre_periodo_eval
          FROM academico_test.TPERIODO_EVALUACION WHERE PK_TPERIODO_EVALUACION = p_pk;
        IF v_nombre_periodo_eval IS NOT NULL THEN
            RAISE EXCEPTION 'El periodo de evaluacion "%" ya se encuentra inactivo', v_nombre_periodo_eval
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe un periodo de evaluacion activo con el PK indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    RETURN p_pk;
END;
$function$;

-- Fuente: V192__fn_periodo_eval_listar_expone_sede.sql
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_listar(
    p_fk_periodo BIGINT,
    p_filtro     TEXT DEFAULT NULL,
    p_page_index INT  DEFAULT 0,
    p_page_size  INT  DEFAULT 10,
    p_pk_usuario BIGINT DEFAULT NULL,
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
           AND academico_test.fn_periodo_puede_ver($5, pe.FK_TPERIODO_ACADEMICO)
         ORDER BY %s %s, pe.PK_TPERIODO_EVALUACION DESC
         LIMIT NULLIF($4, 0)
        OFFSET COALESCE($3, 0) * COALESCE(NULLIF($4, 0), 0)
    $q$, v_col, v_dir)
    USING p_fk_periodo, NULLIF(TRIM(p_filtro),''), p_page_index, p_page_size, p_pk_usuario;
END;
$$;

-- Fuente: V38__evaluation_period_module.sql
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_detalle(
    p_pk BIGINT, p_pk_usuario BIGINT DEFAULT NULL
)
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
     WHERE pe.PK_TPERIODO_EVALUACION = p_pk AND pe.ACTIVE = TRUE
       AND academico_test.fn_periodo_puede_ver(p_pk_usuario, pe.FK_TPERIODO_ACADEMICO);
$$;

-- Fuente: V38__evaluation_period_module.sql
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_eval_bulk_delete(
        p_ids BIGINT[], p_pk_usuario_solicitante BIGINT
    )
    RETURNS TABLE (id BIGINT, eliminado BOOLEAN, error_code TEXT, error_mensaje TEXT)
    LANGUAGE plpgsql AS $$
    DECLARE v_id BIGINT; v_state TEXT; v_msg TEXT;
    BEGIN
        -- CU-86e2w4xdt: capability fail-fast sobre PERIODOS_ACADEMICOS; el
        -- scope fino por (EE, sede, jornada) lo aplica fn_periodo_eval_soft_delete
        -- por cada id dentro del bucle.
        PERFORM academico_test.fn_periodo_gate_escritura(
            p_pk_usuario_solicitante, NULL, NULL, NULL, 'ELIMINAR');
        IF p_ids IS NULL THEN RETURN; END IF;
        FOREACH v_id IN ARRAY p_ids LOOP
            BEGIN
                PERFORM academico_test.fn_periodo_eval_soft_delete(v_id, p_pk_usuario_solicitante);
                id := v_id; eliminado := TRUE; error_code := NULL; error_mensaje := NULL;
                RETURN NEXT;
            EXCEPTION WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
                id := v_id; eliminado := FALSE; error_code := v_state; error_mensaje := v_msg;
                RETURN NEXT;
            END;
        END LOOP;
        RETURN;
    END;
    $$;
