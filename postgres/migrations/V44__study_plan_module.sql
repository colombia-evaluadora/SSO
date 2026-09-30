-- ===========================================================================
-- V44 - Plan de estudio. Quedan fn_plan_soft_delete, fn_plan_asignatura_bulk_delete,
-- fn_plan_listar, fn_plan_obtener y fn_plan_asignaturas_disponibles_listar.
-- fn_plan_agregar/_actualizar/_eliminar/_reporte_listar se reescribieron despues.
-- ===========================================================================


SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_soft_delete(p_fk_grado bigint, p_pk_usuario_solicitante bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_pk_plan BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_grado_nom TEXT;
    v_periodo_id BIGINT;
BEGIN
    SELECT g.FK_TPERIODO_ACADEMICO INTO v_periodo_id
      FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(v_periodo_id),
        academico_test.fn_periodo_sede(v_periodo_id),
        academico_test.fn_periodo_jornada(v_periodo_id), 'ELIMINAR');
    -- Ignora ACTIVE: reusado en ambos mensajes de abajo incluso si el grado esta inactivo.
    SELECT NOMBRE INTO v_grado_nom FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    SELECT PK_TPLAN INTO v_pk_plan FROM academico_test.TPLAN
     WHERE FK_TGRADO = p_fk_grado AND ACTIVE = TRUE;
    IF v_pk_plan IS NULL THEN
        IF v_grado_nom IS NOT NULL THEN
            RAISE EXCEPTION 'No existe un plan de estudio activo para el grado "%"', v_grado_nom USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe un plan de estudio activo para el grado indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    IF EXISTS (
        SELECT 1
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TGRUPO g ON g.FK_TGRADO = p_fk_grado AND g.ACTIVE = TRUE
          JOIN academico_test.TDOCENTE_ASIGNATURA da ON da.FK_TGRUPO = g.PK_TGRUPO
               AND da.FK_TASIGNATURA = ap.FK_TASIGNATURA AND da.ACTIVE = TRUE
         WHERE ap.FK_TPLAN = v_pk_plan AND ap.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el plan del grado "%": hay asignaturas con asignaciones academicas (docentes) activas', v_grado_nom
            USING ERRCODE = '23503';
    END IF;
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Eliminación del plan de estudio completo del grado %s', v_grado_nom),
        academico_test.fn_periodo_establecimiento((
            SELECT g.FK_TPERIODO_ACADEMICO FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado))
    );

    UPDATE academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE ACTIVE = TRUE AND FK_TASIGNATURA_PLAN IN (
         SELECT PK_TASIGNATURA_PLAN FROM academico_test.TASIGNATURA_PLAN
          WHERE FK_TPLAN = v_pk_plan AND ACTIVE = TRUE
     );
    UPDATE academico_test.TASIGNATURA_PLAN SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TPLAN = v_pk_plan AND ACTIVE = TRUE;
    UPDATE academico_test.TPLAN SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TPLAN = v_pk_plan AND ACTIVE = TRUE;
    RETURN v_pk_plan;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_asignatura_bulk_delete(
    p_ids bigint[],
    p_pk_usuario_solicitante bigint
)
RETURNS TABLE(id bigint, eliminado boolean, error_code text, error_mensaje text)
LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_state TEXT; v_msg TEXT;
BEGIN
    IF p_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_ids LOOP
        BEGIN
            PERFORM academico_test.fn_plan_eliminar(v_id, p_pk_usuario_solicitante);
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

DROP FUNCTION IF EXISTS academico_test.fn_plan_listar(BIGINT, TEXT, INT, INT, BIGINT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION academico_test.fn_plan_listar(
    p_fk_grado BIGINT, p_filtro TEXT DEFAULT NULL,
    p_page_index INT DEFAULT 0, p_page_size INT DEFAULT 10,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL,
    
    p_sort_by TEXT DEFAULT NULL,
    p_sort_dir TEXT DEFAULT NULL
)
RETURNS TABLE (codigo BIGINT, asignatura_id BIGINT, asignatura VARCHAR, enfasis_nombre VARCHAR,
               intensidad_horaria NUMERIC, influencia_area NUMERIC,
               numero_creditos BIGINT, influye_desempeno BOOLEAN, matricula_obligatoria BOOLEAN,
               aprobacion_obligatoria BOOLEAN, formato_calificacion BIGINT, criterio_nota BIGINT,
               personalizado BOOLEAN, total_count BIGINT)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'asignatura'        THEN 's.NOMBRE'
        WHEN 'intensidadhoraria' THEN 'ap.NUMERO_HORA'
        WHEN 'influenciaarea'    THEN 'ap.INFLUENCIA_AREA'
        WHEN 'numerocreditos'    THEN 'ap.NUMERO_CREDITO'
        ELSE 's.NOMBRE'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'desc' THEN 'DESC' ELSE 'ASC' END;

    RETURN QUERY EXECUTE format($q$
        SELECT ap.PK_TASIGNATURA_PLAN, s.PK_TASIGNATURA, s.NOMBRE, e.NOMBRE,
               ap.NUMERO_HORA, ap.INFLUENCIA_AREA, ap.NUMERO_CREDITO,
               (ap.INFLUYE_DESEMPLENO_ACADEMICO = 'S'), (ap.MATRICULA_OBLIGATORIA = 'S'),
               (ap.APROBACION_OBLIGATORIA = 'S'),
               COALESCE(ap.FK_TLV_FORMATO_CALIFICACION_DEF, ce.FK_TLV_FORMATO_CALIFICACION),
               COALESCE(ap.FK_TLV_CALCULO_DEFINITIVA,      ce.FK_TLV_MODIF_FINAL_PERACA),
               (ap.FK_TLV_FORMATO_CALIFICACION_DEF IS NOT NULL OR ap.FK_TLV_CALCULO_DEFINITIVA IS NOT NULL),
               count(*) OVER()::BIGINT
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN p        ON p.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRADO g       ON g.PK_TGRADO = p.FK_TGRADO
          JOIN academico_test.TASIGNATURA s  ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA
          LEFT JOIN academico_test.TENFASIS e ON e.PK_TENFASIS = s.FK_TENFASIS AND e.ACTIVE = TRUE
          LEFT JOIN academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN cap
                 ON cap.FK_TASIGNATURA_PLAN = ap.PK_TASIGNATURA_PLAN AND cap.ACTIVE = TRUE
          LEFT JOIN academico_test.TCRITERIO_EVALUACION ce
                 ON ce.PK_TCRITERIO_EVALUACION = cap.FK_TCRITERIO_EVALUACION AND ce.ACTIVE = TRUE
         WHERE p.FK_TGRADO = $1 AND ap.ACTIVE = TRUE
           AND ($2 IS NULL OR s.NOMBRE ILIKE '%%' || $2 || '%%')
           AND academico_test.fn_periodo_puede_ver($5, g.FK_TPERIODO_ACADEMICO)
         ORDER BY %s %s, ap.PK_TASIGNATURA_PLAN
         LIMIT NULLIF($4, 0)
        OFFSET COALESCE($3, 0) * COALESCE(NULLIF($4, 0), 0)
    $q$, v_col, v_dir)
    USING p_fk_grado, NULLIF(TRIM(p_filtro),''), p_page_index, p_page_size, p_pk_usuario_solicitante;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_obtener(
    p_pk BIGINT, p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (codigo BIGINT, asignatura_id BIGINT, asignatura VARCHAR,
               intensidad_horaria NUMERIC, influencia_area NUMERIC, numero_creditos BIGINT,
               influye_desempeno BOOLEAN, matricula_obligatoria BOOLEAN, aprobacion_obligatoria BOOLEAN,
               formato_calificacion BIGINT, criterio_nota BIGINT, personalizado BOOLEAN, grado_id BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT ap.PK_TASIGNATURA_PLAN, ap.FK_TASIGNATURA, s.NOMBRE,
           ap.NUMERO_HORA, ap.INFLUENCIA_AREA, ap.NUMERO_CREDITO,
           (ap.INFLUYE_DESEMPLENO_ACADEMICO = 'S'), (ap.MATRICULA_OBLIGATORIA = 'S'),
           (ap.APROBACION_OBLIGATORIA = 'S'),
           COALESCE(ap.FK_TLV_FORMATO_CALIFICACION_DEF, ce.FK_TLV_FORMATO_CALIFICACION),
           COALESCE(ap.FK_TLV_CALCULO_DEFINITIVA,      ce.FK_TLV_MODIF_FINAL_PERACA),
           (ap.FK_TLV_FORMATO_CALIFICACION_DEF IS NOT NULL OR ap.FK_TLV_CALCULO_DEFINITIVA IS NOT NULL),
           p.FK_TGRADO
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN p        ON p.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TGRADO g       ON g.PK_TGRADO = p.FK_TGRADO
      JOIN academico_test.TASIGNATURA s  ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA
      LEFT JOIN academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN cap
             ON cap.FK_TASIGNATURA_PLAN = ap.PK_TASIGNATURA_PLAN AND cap.ACTIVE = TRUE
      LEFT JOIN academico_test.TCRITERIO_EVALUACION ce
             ON ce.PK_TCRITERIO_EVALUACION = cap.FK_TCRITERIO_EVALUACION AND ce.ACTIVE = TRUE
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk AND ap.ACTIVE = TRUE
       AND academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante, g.FK_TPERIODO_ACADEMICO);
$$;

DROP FUNCTION IF EXISTS academico_test.fn_plan_asignaturas_disponibles_listar(BIGINT, TEXT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_plan_asignaturas_disponibles_listar(
    p_fk_grado BIGINT, p_filtro TEXT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, nombre VARCHAR, area_id BIGINT, area_nombre VARCHAR, enfasis_nombre VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT s.PK_TASIGNATURA, s.NOMBRE, a.PK_TAREA, a.NOMBRE, e.NOMBRE
      FROM academico_test.TGRADO g
      JOIN academico_test.TAREA a       ON a.FK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO AND a.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA s ON s.FK_TAREA = a.PK_TAREA AND s.ACTIVE = TRUE
      LEFT JOIN academico_test.TENFASIS e ON e.PK_TENFASIS = s.FK_TENFASIS AND e.ACTIVE = TRUE
     WHERE g.PK_TGRADO = p_fk_grado
       AND (NULLIF(TRIM(p_filtro),'') IS NULL OR s.NOMBRE ILIKE '%' || p_filtro || '%')
       AND NOT EXISTS (
             SELECT 1 FROM academico_test.TASIGNATURA_PLAN ap
               JOIN academico_test.TPLAN p ON p.PK_TPLAN = ap.FK_TPLAN
              WHERE p.FK_TGRADO = p_fk_grado AND ap.FK_TASIGNATURA = s.PK_TASIGNATURA AND ap.ACTIVE = TRUE)
       AND academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante, g.FK_TPERIODO_ACADEMICO)
     ORDER BY a.NOMBRE, s.NOMBRE;
$$;
