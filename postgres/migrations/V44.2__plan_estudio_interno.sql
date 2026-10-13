-- ===========================================================================
-- V44.2 -- Plan de estudio: nucleos _interno
-- ===========================================================================
-- QUE HACE: agregar/actualizar/quitar renglones del plan, dar de baja el plan
-- de un grado, listados, detalle y el chequeo previo de restricciones, todo
-- sin permisos. Validan con V44.1; el gate, el alcance y la auditoria van en
-- V44.3. En preescolar resincronizan a los directores de grupo del grado.
-- POR QUE AQUI: capa 2 del modulo (V44.1 / V44.2 / V44.3).
-- DEPENDE DE: V22, V44.1, V43.2 (fn_grado_es_preescolar,
-- fn_docente_director_grupo_sync); fn_docente_grado_directores_sync va al final.
-- ===========================================================================

SET search_path TO academico_test, public;

-- El TPLAN del grado se crea con el primer renglon.
CREATE OR REPLACE FUNCTION academico_test.fn_plan_agregar_interno(
    p_fk_grado               BIGINT,
    p_fk_asignatura          BIGINT,
    p_numero_hora            NUMERIC,
    p_influencia_area        NUMERIC,
    p_numero_credito         BIGINT,
    p_influye_desempeno      BOOLEAN,
    p_matricula_obligatoria  BOOLEAN,
    p_aprobacion_obligatoria BOOLEAN,
    p_fk_formato_calif       BIGINT,
    p_fk_criterio_nota       BIGINT,
    p_audit                  VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_grado_nom TEXT; v_plan_id BIGINT; v_id BIGINT; v_periodo BIGINT;
    v_usuario BIGINT := CASE WHEN p_audit ~ '^[0-9]+$' THEN p_audit::BIGINT END;
BEGIN
    PERFORM academico_test.fn_plan_validar_campos(p_fk_grado, p_fk_asignatura);
    PERFORM academico_test.fn_plan_validar_valores(p_numero_hora, p_influencia_area, p_numero_credito);
    PERFORM academico_test.fn_plan_validar_grado(p_fk_grado);
    PERFORM academico_test.fn_plan_validar_asignatura(p_fk_asignatura);
    PERFORM academico_test.fn_plan_validar_formato_calificacion(p_fk_formato_calif);
    PERFORM academico_test.fn_plan_validar_criterio_nota(p_fk_criterio_nota);
    SELECT NOMBRE, FK_TPERIODO_ACADEMICO INTO v_grado_nom, v_periodo
      FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;

    -- Serializa por grado: dos altas simultaneas no deben crear dos TPLAN activos.
    PERFORM pg_advisory_xact_lock(hashtext('plan:' || p_fk_grado::text));
    SELECT PK_TPLAN INTO v_plan_id FROM academico_test.TPLAN WHERE FK_TGRADO = p_fk_grado AND ACTIVE = TRUE;
    IF v_plan_id IS NULL THEN
        INSERT INTO academico_test.TPLAN (CODIGO, NOMBRE, FK_TGRADO, CREATED_BY)
        VALUES (LEFT(v_grado_nom, 30), 'Plan ' || v_grado_nom, p_fk_grado, p_audit)
        RETURNING PK_TPLAN INTO v_plan_id;
    END IF;
    PERFORM academico_test.fn_plan_validar_asignatura_unica(v_plan_id, p_fk_asignatura);

    INSERT INTO academico_test.TASIGNATURA_PLAN (
        FK_TPLAN, FK_TASIGNATURA, NUMERO_HORA, INFLUENCIA_AREA, NUMERO_CREDITO,
        INFLUYE_DESEMPLENO_ACADEMICO, MATRICULA_OBLIGATORIA, APROBACION_OBLIGATORIA,
        FK_TLV_FORMATO_CALIFICACION_DEF, FK_TLV_CALCULO_DEFINITIVA, CREATED_BY
    ) VALUES (
        v_plan_id, p_fk_asignatura, p_numero_hora, p_influencia_area, p_numero_credito,
        CASE WHEN p_influye_desempeno THEN 'S' ELSE 'N' END::academico_test.bool_sn,
        CASE WHEN p_matricula_obligatoria THEN 'S' ELSE 'N' END::academico_test.bool_sn,
        CASE WHEN p_aprobacion_obligatoria THEN 'S' ELSE 'N' END,
        p_fk_formato_calif, p_fk_criterio_nota, p_audit
    )
    RETURNING PK_TASIGNATURA_PLAN INTO v_id;

    -- TCRITERIO_EVALUACION comparte pk con su periodo (1:1, FK_TCRITERIO_EVALUACION_1).
    IF EXISTS (
        SELECT 1 FROM academico_test.TCRITERIO_EVALUACION
         WHERE PK_TCRITERIO_EVALUACION = v_periodo AND ACTIVE = TRUE
    ) THEN
        INSERT INTO academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN
            (FK_TCRITERIO_EVALUACION, FK_TASIGNATURA_PLAN, FK_TGRADO, POR_DEFECTO, CREATED_BY)
        VALUES (v_periodo, v_id, NULL, 'S', p_audit);
    END IF;

    IF academico_test.fn_grado_es_preescolar(p_fk_grado) THEN
        PERFORM academico_test.fn_docente_grado_directores_sync(p_fk_grado, NULL, v_usuario);
    END IF;
    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_plan_agregar_interno(BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, BOOLEAN, BOOLEAN, BOOLEAN, BIGINT, BIGINT, VARCHAR)
    IS 'INTERNO: valida y agrega una asignatura al plan del grado (creando el TPLAN si no hay) y, en preescolar, resincroniza a los directores. Lo usa fn_plan_agregar.';

-- Los NULL conservan el valor, salvo formato y criterio: NULL = vuelve a heredar del criterio de evaluacion.
CREATE OR REPLACE FUNCTION academico_test.fn_plan_actualizar_interno(
    p_pk                     BIGINT,
    p_fk_asignatura          BIGINT,
    p_numero_hora            NUMERIC,
    p_influencia_area        NUMERIC,
    p_numero_credito         BIGINT,
    p_influye_desempeno      BOOLEAN,
    p_matricula_obligatoria  BOOLEAN,
    p_aprobacion_obligatoria BOOLEAN,
    p_fk_formato_calif       BIGINT,
    p_fk_criterio_nota       BIGINT,
    p_audit                  VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_plan_id BIGINT; v_grado_id BIGINT;
    v_usuario BIGINT := CASE WHEN p_audit ~ '^[0-9]+$' THEN p_audit::BIGINT END;
BEGIN
    SELECT ap.FK_TPLAN, pl.FK_TGRADO INTO v_plan_id, v_grado_id
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk;
    PERFORM academico_test.fn_plan_validar_valores(p_numero_hora, p_influencia_area, p_numero_credito);
    IF p_fk_asignatura IS NOT NULL THEN
        PERFORM academico_test.fn_plan_validar_asignatura(p_fk_asignatura);
        PERFORM academico_test.fn_plan_validar_asignatura_unica(v_plan_id, p_fk_asignatura, p_pk);
    END IF;
    PERFORM academico_test.fn_plan_validar_formato_calificacion(p_fk_formato_calif);
    PERFORM academico_test.fn_plan_validar_criterio_nota(p_fk_criterio_nota);

    UPDATE academico_test.TASIGNATURA_PLAN SET
        FK_TASIGNATURA = COALESCE(p_fk_asignatura, FK_TASIGNATURA),
        NUMERO_HORA = COALESCE(p_numero_hora, NUMERO_HORA),
        INFLUENCIA_AREA = COALESCE(p_influencia_area, INFLUENCIA_AREA),
        NUMERO_CREDITO = COALESCE(p_numero_credito, NUMERO_CREDITO),
        INFLUYE_DESEMPLENO_ACADEMICO = CASE WHEN p_influye_desempeno IS NULL THEN INFLUYE_DESEMPLENO_ACADEMICO
                                            WHEN p_influye_desempeno THEN 'S' ELSE 'N' END::academico_test.bool_sn,
        MATRICULA_OBLIGATORIA = CASE WHEN p_matricula_obligatoria IS NULL THEN MATRICULA_OBLIGATORIA
                                     WHEN p_matricula_obligatoria THEN 'S' ELSE 'N' END::academico_test.bool_sn,
        APROBACION_OBLIGATORIA = CASE WHEN p_aprobacion_obligatoria IS NULL THEN APROBACION_OBLIGATORIA
                                      WHEN p_aprobacion_obligatoria THEN 'S' ELSE 'N' END,
        FK_TLV_FORMATO_CALIFICACION_DEF = p_fk_formato_calif,
        FK_TLV_CALCULO_DEFINITIVA = p_fk_criterio_nota,
        MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TASIGNATURA_PLAN = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        PERFORM academico_test.fn_plan_validar_renglon_activo(p_pk);
        RAISE EXCEPTION 'No existe un renglon de plan activo con el identificador indicado' USING ERRCODE = 'P0002';
    END IF;

    -- Cambiar un renglon puede cambiar el conjunto de asignaturas del grado.
    IF academico_test.fn_grado_es_preescolar(v_grado_id) THEN
        PERFORM academico_test.fn_docente_grado_directores_sync(v_grado_id, NULL, v_usuario);
    END IF;
    RETURN p_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_plan_actualizar_interno(BIGINT, BIGINT, NUMERIC, NUMERIC, BIGINT, BOOLEAN, BOOLEAN, BOOLEAN, BIGINT, BIGINT, VARCHAR)
    IS 'INTERNO: valida y actualiza un renglon activo del plan y, en preescolar, resincroniza a los directores del grado. Lo usa fn_plan_actualizar.';

CREATE OR REPLACE FUNCTION academico_test.fn_plan_eliminar_interno(p_pk BIGINT, p_audit VARCHAR)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_plan_id BIGINT; v_grado_id BIGINT; v_asignatura_id BIGINT;
    v_usuario BIGINT := CASE WHEN p_audit ~ '^[0-9]+$' THEN p_audit::BIGINT END;
BEGIN
    SELECT ap.FK_TPLAN, pl.FK_TGRADO, ap.FK_TASIGNATURA INTO v_plan_id, v_grado_id, v_asignatura_id
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk;

    -- Antes de los bloqueos: si el unico docente de la pareja era el director
    -- auto-asignado (preescolar), al resincronizar sin la asignatura deja de bloquear.
    IF academico_test.fn_grado_es_preescolar(v_grado_id) THEN
        PERFORM academico_test.fn_docente_grado_directores_sync(v_grado_id, v_asignatura_id, v_usuario);
    END IF;
    PERFORM academico_test.fn_plan_validar_renglon_removible(p_pk);

    UPDATE academico_test.TASIGNATURA_PLAN SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TASIGNATURA_PLAN = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        PERFORM academico_test.fn_plan_validar_renglon_activo(p_pk);
        RAISE EXCEPTION 'No existe un renglon de plan activo con el identificador indicado' USING ERRCODE = 'P0002';
    END IF;
    UPDATE academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN
       SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TASIGNATURA_PLAN = p_pk AND ACTIVE = TRUE;
    -- Un plan sin renglones activos se da de baja con el ultimo.
    IF v_plan_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA_PLAN WHERE FK_TPLAN = v_plan_id AND ACTIVE = TRUE
    ) THEN
        UPDATE academico_test.TPLAN
           SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TPLAN = v_plan_id AND ACTIVE = TRUE;
    END IF;
    RETURN p_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_plan_eliminar_interno(BIGINT, VARCHAR)
    IS 'INTERNO: quita un renglon del plan (y el plan si queda vacio); 23503 si hay docente u horario en grupos del grado, P0002 si ya estaba inactivo. Lo usa fn_plan_eliminar.';

CREATE OR REPLACE FUNCTION academico_test.fn_plan_grado_eliminar_interno(p_fk_grado BIGINT, p_audit VARCHAR)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_pk_plan BIGINT;
BEGIN
    PERFORM academico_test.fn_plan_validar_existe_para_grado(p_fk_grado);
    SELECT PK_TPLAN INTO v_pk_plan FROM academico_test.TPLAN WHERE FK_TGRADO = p_fk_grado AND ACTIVE = TRUE;
    PERFORM academico_test.fn_plan_validar_sin_asignaciones(v_pk_plan);

    UPDATE academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN
       SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE ACTIVE = TRUE AND FK_TASIGNATURA_PLAN IN (
         SELECT PK_TASIGNATURA_PLAN FROM academico_test.TASIGNATURA_PLAN
          WHERE FK_TPLAN = v_pk_plan AND ACTIVE = TRUE
     );
    UPDATE academico_test.TASIGNATURA_PLAN SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TPLAN = v_pk_plan AND ACTIVE = TRUE;
    UPDATE academico_test.TPLAN SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TPLAN = v_pk_plan AND ACTIVE = TRUE;
    RETURN v_pk_plan;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_plan_grado_eliminar_interno(BIGINT, VARCHAR)
    IS 'INTERNO: baja logica del plan activo de un grado con todos sus renglones; P0002 si no hay plan, 23503 si alguna asignatura tiene docente en el grado. Lo usa fn_plan_soft_delete.';

CREATE OR REPLACE FUNCTION academico_test.fn_plan_listar_interno(
    p_fk_grado   BIGINT,
    p_filtro     TEXT DEFAULT NULL,
    p_page_index INT  DEFAULT 0,
    p_page_size  INT  DEFAULT 10,
    p_sort_by    TEXT DEFAULT NULL,
    p_sort_dir   TEXT DEFAULT NULL
)
RETURNS TABLE (codigo BIGINT, asignatura_id BIGINT, asignatura VARCHAR, enfasis_nombre VARCHAR,
               intensidad_horaria NUMERIC, influencia_area NUMERIC,
               numero_creditos BIGINT, influye_desempeno BOOLEAN, matricula_obligatoria BOOLEAN,
               aprobacion_obligatoria BOOLEAN, formato_calificacion BIGINT, criterio_nota BIGINT,
               personalizado BOOLEAN, total_count BIGINT,
               abreviacion VARCHAR, especialidad_id BIGINT)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_col TEXT; v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'asignatura'        THEN 's.NOMBRE'
        WHEN 'intensidadhoraria' THEN 'ap.NUMERO_HORA'
        WHEN 'influenciaarea'    THEN 'ap.INFLUENCIA_AREA'
        WHEN 'numerocreditos'    THEN 'ap.NUMERO_CREDITO'
        ELSE 's.NOMBRE'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'desc' THEN 'DESC' ELSE 'ASC' END;

    -- Formato y criterio del renglon, o los heredados del criterio de evaluacion.
    RETURN QUERY EXECUTE format($q$
        SELECT ap.PK_TASIGNATURA_PLAN, s.PK_TASIGNATURA, s.NOMBRE, e.NOMBRE,
               ap.NUMERO_HORA, ap.INFLUENCIA_AREA, ap.NUMERO_CREDITO,
               (ap.INFLUYE_DESEMPLENO_ACADEMICO = 'S'), (ap.MATRICULA_OBLIGATORIA = 'S'),
               (ap.APROBACION_OBLIGATORIA = 'S'),
               COALESCE(ap.FK_TLV_FORMATO_CALIFICACION_DEF, ce.FK_TLV_FORMATO_CALIFICACION),
               COALESCE(ap.FK_TLV_CALCULO_DEFINITIVA,      ce.FK_TLV_MODIF_FINAL_PERACA),
               (ap.FK_TLV_FORMATO_CALIFICACION_DEF IS NOT NULL OR ap.FK_TLV_CALCULO_DEFINITIVA IS NOT NULL),
               count(*) OVER()::BIGINT, s.ABREVIACION, s.FK_TENFASIS
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN p        ON p.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TASIGNATURA s  ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA
          LEFT JOIN academico_test.TENFASIS e ON e.PK_TENFASIS = s.FK_TENFASIS AND e.ACTIVE = TRUE
          LEFT JOIN academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN cap
                 ON cap.FK_TASIGNATURA_PLAN = ap.PK_TASIGNATURA_PLAN AND cap.ACTIVE = TRUE
          LEFT JOIN academico_test.TCRITERIO_EVALUACION ce
                 ON ce.PK_TCRITERIO_EVALUACION = cap.FK_TCRITERIO_EVALUACION AND ce.ACTIVE = TRUE
         WHERE p.FK_TGRADO = $1 AND ap.ACTIVE = TRUE
           AND ($2 IS NULL OR s.NOMBRE ILIKE '%%' || $2 || '%%')
         ORDER BY %s %s, ap.PK_TASIGNATURA_PLAN
         LIMIT NULLIF($4, 0)
        OFFSET COALESCE($3, 0) * COALESCE(NULLIF($4, 0), 0)
    $q$, v_col, v_dir)
    USING p_fk_grado, NULLIF(TRIM(p_filtro),''), p_page_index, p_page_size;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_plan_listar_interno(BIGINT, TEXT, INT, INT, TEXT, TEXT)
    IS 'INTERNO: renglones activos del plan de un grado, paginados y ordenados, sin alcance. Lo usan fn_plan_listar y fn_plan_reporte_listar.';

CREATE OR REPLACE FUNCTION academico_test.fn_plan_obtener_interno(p_pk BIGINT)
RETURNS TABLE (codigo BIGINT, asignatura_id BIGINT, asignatura VARCHAR,
               intensidad_horaria NUMERIC, influencia_area NUMERIC, numero_creditos BIGINT,
               influye_desempeno BOOLEAN, matricula_obligatoria BOOLEAN, aprobacion_obligatoria BOOLEAN,
               formato_calificacion BIGINT, criterio_nota BIGINT, personalizado BOOLEAN, grado_id BIGINT,
               academic_period_id BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT ap.PK_TASIGNATURA_PLAN, ap.FK_TASIGNATURA, s.NOMBRE,
           ap.NUMERO_HORA, ap.INFLUENCIA_AREA, ap.NUMERO_CREDITO,
           (ap.INFLUYE_DESEMPLENO_ACADEMICO = 'S'), (ap.MATRICULA_OBLIGATORIA = 'S'),
           (ap.APROBACION_OBLIGATORIA = 'S'),
           COALESCE(ap.FK_TLV_FORMATO_CALIFICACION_DEF, ce.FK_TLV_FORMATO_CALIFICACION),
           COALESCE(ap.FK_TLV_CALCULO_DEFINITIVA,      ce.FK_TLV_MODIF_FINAL_PERACA),
           (ap.FK_TLV_FORMATO_CALIFICACION_DEF IS NOT NULL OR ap.FK_TLV_CALCULO_DEFINITIVA IS NOT NULL),
           p.FK_TGRADO, g.FK_TPERIODO_ACADEMICO
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN p        ON p.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TGRADO g       ON g.PK_TGRADO = p.FK_TGRADO
      JOIN academico_test.TASIGNATURA s  ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA
      LEFT JOIN academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN cap
             ON cap.FK_TASIGNATURA_PLAN = ap.PK_TASIGNATURA_PLAN AND cap.ACTIVE = TRUE
      LEFT JOIN academico_test.TCRITERIO_EVALUACION ce
             ON ce.PK_TCRITERIO_EVALUACION = cap.FK_TCRITERIO_EVALUACION AND ce.ACTIVE = TRUE
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk AND ap.ACTIVE = TRUE;
$$;

COMMENT ON FUNCTION academico_test.fn_plan_obtener_interno(BIGINT)
    IS 'INTERNO: un renglon activo del plan con su grado y periodo academico, sin alcance. Lo usa fn_plan_obtener.';

-- Asignaturas activas de las areas del periodo del grado que aun no estan en su plan.
CREATE OR REPLACE FUNCTION academico_test.fn_plan_asignaturas_disponibles_listar_interno(
    p_fk_grado BIGINT, p_filtro TEXT DEFAULT NULL
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
     ORDER BY a.NOMBRE, s.NOMBRE;
$$;

COMMENT ON FUNCTION academico_test.fn_plan_asignaturas_disponibles_listar_interno(BIGINT, TEXT)
    IS 'INTERNO: asignaturas que se pueden agregar al plan de un grado, sin alcance. Lo usa fn_plan_asignaturas_disponibles_listar.';

-- Remover (quitar de ESTE plan) lo bloquea docente u horario en grupos de este
-- grado; Eliminar (ademas borrar la asignatura) tambien lo de cualquier grado,
-- las notas y que otro grado la tenga en su plan. En preescolar no cuenta el
-- director auto-asignado del propio grupo: fn_plan_eliminar lo desasigna solo.
CREATE OR REPLACE FUNCTION academico_test.fn_plan_eliminar_restricciones_interno(p_pk BIGINT)
RETURNS TABLE (puede_eliminar BOOLEAN, puede_remover BOOLEAN, motivo TEXT, grado_conflicto TEXT)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_asignatura_id BIGINT; v_grado_id BIGINT; v_preescolar BOOLEAN; v_grado_conflicto TEXT;
BEGIN
    SELECT ap.FK_TASIGNATURA, pl.FK_TGRADO INTO v_asignatura_id, v_grado_id
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk AND ap.ACTIVE = TRUE;

    -- Endpoint de chequeo: un renglon ya borrado (otra pestana) responde, no lanza.
    IF v_asignatura_id IS NULL THEN
        RETURN QUERY SELECT FALSE, FALSE,
            'No existe un renglón de plan activo con el identificador indicado'::TEXT, NULL::TEXT;
        RETURN;
    END IF;
    v_preescolar := academico_test.fn_grado_es_preescolar(v_grado_id);

    IF EXISTS (
        SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
          JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = da.FK_TGRUPO AND gr.FK_TGRADO = v_grado_id
         WHERE da.FK_TASIGNATURA = v_asignatura_id AND da.ACTIVE = TRUE
           AND (NOT v_preescolar OR da.FK_TFUNCIONARIO IS DISTINCT FROM gr.FK_TFUNCIONARIO)
    ) THEN
        RETURN QUERY SELECT FALSE, FALSE, 'tiene un docente asignado en un grupo de este grado'::TEXT, NULL::TEXT;
        RETURN;
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.THORARIO h
          JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = h.FK_TGRUPO AND gr.FK_TGRADO = v_grado_id
         WHERE h.FK_TASIGNATURA = v_asignatura_id AND h.ACTIVE = TRUE
    ) THEN
        RETURN QUERY SELECT FALSE, FALSE, 'tiene bloques de horario configurados en un grupo de este grado'::TEXT, NULL::TEXT;
        RETURN;
    END IF;

    -- Desde aqui Remover funciona; lo que sigue solo decide Eliminar.
    IF EXISTS (
        SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
          JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = da.FK_TGRUPO
         WHERE da.FK_TASIGNATURA = v_asignatura_id AND da.ACTIVE = TRUE
           AND (NOT v_preescolar OR da.FK_TFUNCIONARIO IS DISTINCT FROM gr.FK_TFUNCIONARIO)
    ) THEN
        RETURN QUERY SELECT FALSE, TRUE, 'tiene un docente asignado'::TEXT, NULL::TEXT;
        RETURN;
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.THORARIO h WHERE h.FK_TASIGNATURA = v_asignatura_id AND h.ACTIVE = TRUE
    ) THEN
        RETURN QUERY SELECT FALSE, TRUE, 'tiene bloques de horario configurados'::TEXT, NULL::TEXT;
        RETURN;
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA_NOTA an WHERE an.FK_TASIGNATURA = v_asignatura_id AND an.ACTIVE = TRUE
    ) THEN
        RETURN QUERY SELECT FALSE, TRUE, 'tiene calificaciones registradas'::TEXT, NULL::TEXT;
        RETURN;
    END IF;

    SELECT tg.NOMBRE INTO v_grado_conflicto
      FROM academico_test.TASIGNATURA_PLAN ap2
      JOIN academico_test.TPLAN pl2 ON pl2.PK_TPLAN = ap2.FK_TPLAN
      JOIN academico_test.TGRADO tg ON tg.PK_TGRADO = pl2.FK_TGRADO
     WHERE ap2.FK_TASIGNATURA = v_asignatura_id AND ap2.ACTIVE = TRUE AND ap2.PK_TASIGNATURA_PLAN <> p_pk
     LIMIT 1;
    IF v_grado_conflicto IS NOT NULL THEN
        RETURN QUERY SELECT FALSE, TRUE, format('está en el plan de estudio del grado "%s"', v_grado_conflicto),
            v_grado_conflicto;
        RETURN;
    END IF;

    RETURN QUERY SELECT TRUE, TRUE, NULL::TEXT, NULL::TEXT;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_plan_eliminar_restricciones_interno(BIGINT)
    IS 'INTERNO: si un renglon del plan se puede remover (fn_plan_eliminar) y/o eliminar con su asignatura (fn_subject_soft_delete), y el primer motivo que lo impide. Sin alcance. Lo usa fn_plan_eliminar_restricciones.';

-- ------------------------------------- director de grupo (antes V285)
-- Version "por grado": sincroniza a todos los directores distintos que
-- tengan al menos un grupo activo en p_fk_grado. Usada por fn_plan_agregar_interno /
-- fn_plan_actualizar_interno / fn_plan_eliminar_interno (V44.2), que no saben de
-- antemano cuantos directores distintos hay en el grado.
CREATE OR REPLACE FUNCTION academico_test.fn_docente_grado_directores_sync(
    p_fk_grado BIGINT,
    p_excluir_asignatura BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_periodo BIGINT;
    v_func BIGINT;
    v_skipped INT := 0;
BEGIN
    SELECT FK_TPERIODO_ACADEMICO INTO v_periodo
      FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    IF v_periodo IS NULL THEN
        RETURN 0;
    END IF;

    FOR v_func IN
        SELECT DISTINCT FK_TFUNCIONARIO
          FROM academico_test.TGRUPO
         WHERE FK_TGRADO = p_fk_grado AND ACTIVE = TRUE AND FK_TFUNCIONARIO IS NOT NULL
    LOOP
        v_skipped := v_skipped + academico_test.fn_docente_director_grupo_sync(
            v_func, v_periodo, p_excluir_asignatura, p_pk_usuario_solicitante);
    END LOOP;

    RETURN v_skipped;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_docente_grado_directores_sync IS
    'Sincroniza (fn_docente_director_grupo_sync) a cada director distinto con '
    'grupo activo en un grado. Ver V301.';
