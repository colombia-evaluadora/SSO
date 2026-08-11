-- ===========================================================================
-- V44 — Modulo de Plan de Estudio (TPLAN + TASIGNATURA_PLAN). Convencion de
-- funciones (ver V37). El plan (TPLAN) se crea/busca por grado (uno por grado);
-- cada renglon es una TASIGNATURA_PLAN. Bools del front -> bool_sn/'S'/'N'.
-- formato/criterio NULL = hereda del criterio de evaluacion del periodo.
-- ===========================================================================

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_agregar(
    p_fk_grado             BIGINT,
    p_fk_asignatura        BIGINT,
    p_numero_hora          NUMERIC,
    p_influencia_area      NUMERIC,
    p_numero_credito       BIGINT,
    p_influye_desempeno    BOOLEAN,
    p_matricula_obligatoria BOOLEAN,
    p_aprobacion_obligatoria BOOLEAN,
    p_fk_formato_calif     BIGINT DEFAULT NULL,
    p_fk_criterio_nota     BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_grado_nom TEXT; v_plan_id BIGINT; v_id BIGINT; v_periodo BIGINT;
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado));
    IF p_fk_grado IS NULL OR p_fk_asignatura IS NULL THEN
        RAISE EXCEPTION 'Grado y asignatura son obligatorios' USING ERRCODE = '22023';
    END IF;
    -- Validaciones numericas.
    IF p_numero_hora IS NOT NULL AND p_numero_hora <= 0 THEN
        RAISE EXCEPTION 'La intensidad horaria debe ser mayor a 0' USING ERRCODE = '22023';
    END IF;
    IF p_influencia_area IS NOT NULL AND (p_influencia_area < 0 OR p_influencia_area > 100) THEN
        RAISE EXCEPTION 'La influencia en el area (%%) debe estar entre 0 y 100' USING ERRCODE = '22023';
    END IF;
    IF p_numero_credito IS NOT NULL AND p_numero_credito < 0 THEN
        RAISE EXCEPTION 'El numero de creditos no puede ser negativo' USING ERRCODE = '22023';
    END IF;

    SELECT NOMBRE INTO v_grado_nom FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado AND ACTIVE = TRUE;
    IF v_grado_nom IS NULL THEN
        RAISE EXCEPTION 'El grado % no existe o esta inactivo', p_fk_grado USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_asignatura AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'La asignatura % no existe o esta inactiva', p_fk_asignatura USING ERRCODE = '23503';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('plan:' || p_fk_grado::text));
    SELECT PK_TPLAN INTO v_plan_id FROM academico_test.TPLAN WHERE FK_TGRADO = p_fk_grado AND ACTIVE = TRUE;
    IF v_plan_id IS NULL THEN
        INSERT INTO academico_test.TPLAN (CODIGO, NOMBRE, FK_TGRADO, CREATED_BY)
        VALUES (LEFT(v_grado_nom, 30), 'Plan ' || v_grado_nom, p_fk_grado, v_audit)
        RETURNING PK_TPLAN INTO v_plan_id;
    END IF;
    -- No permitir la misma asignatura dos veces en el plan del grado.
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA_PLAN
         WHERE FK_TPLAN = v_plan_id AND FK_TASIGNATURA = p_fk_asignatura AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'La asignatura % ya esta en el plan de estudio de este grado', p_fk_asignatura
            USING ERRCODE = '23505';
    END IF;

    INSERT INTO academico_test.TASIGNATURA_PLAN (
        FK_TPLAN, FK_TASIGNATURA, NUMERO_HORA, INFLUENCIA_AREA, NUMERO_CREDITO,
        INFLUYE_DESEMPLENO_ACADEMICO, MATRICULA_OBLIGATORIA, APROBACION_OBLIGATORIA,
        FK_TLV_FORMATO_CALIFICACION_DEF, FK_TLV_CALCULO_DEFINITIVA, CREATED_BY
    ) VALUES (
        v_plan_id, p_fk_asignatura, p_numero_hora, p_influencia_area, p_numero_credito,
        CASE WHEN p_influye_desempeno THEN 'S' ELSE 'N' END::academico_test.bool_sn,
        CASE WHEN p_matricula_obligatoria THEN 'S' ELSE 'N' END::academico_test.bool_sn,
        CASE WHEN p_aprobacion_obligatoria THEN 'S' ELSE 'N' END,
        p_fk_formato_calif, p_fk_criterio_nota, v_audit
    )
    RETURNING PK_TASIGNATURA_PLAN INTO v_id;

    -- Enlaza el renglon del plan con el criterio de evaluacion POR DEFECTO del
    -- periodo (PK del criterio = PK del periodo). Los overrides personalizados
    -- de formato/criterio-nota viven en las columnas de TASIGNATURA_PLAN.
    SELECT FK_TPERIODO_ACADEMICO INTO v_periodo FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    IF EXISTS (
        SELECT 1 FROM academico_test.TCRITERIO_EVALUACION
         WHERE PK_TCRITERIO_EVALUACION = v_periodo AND ACTIVE = TRUE
    ) THEN
        INSERT INTO academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN
            (FK_TCRITERIO_EVALUACION, FK_TASIGNATURA_PLAN, FK_TGRADO, POR_DEFECTO, CREATED_BY)
        VALUES (v_periodo, v_id, NULL, 'S', v_audit);
    END IF;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_actualizar(
    p_pk                   BIGINT,
    p_fk_asignatura        BIGINT  DEFAULT NULL,
    p_numero_hora          NUMERIC DEFAULT NULL,
    p_influencia_area      NUMERIC DEFAULT NULL,
    p_numero_credito       BIGINT  DEFAULT NULL,
    p_influye_desempeno    BOOLEAN DEFAULT NULL,
    p_matricula_obligatoria BOOLEAN DEFAULT NULL,
    p_aprobacion_obligatoria BOOLEAN DEFAULT NULL,
    p_fk_formato_calif     BIGINT  DEFAULT NULL,
    p_fk_criterio_nota     BIGINT  DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
         WHERE ap.PK_TASIGNATURA_PLAN = p_pk));
    -- Validaciones numericas (solo si vienen).
    IF p_numero_hora IS NOT NULL AND p_numero_hora <= 0 THEN
        RAISE EXCEPTION 'La intensidad horaria debe ser mayor a 0' USING ERRCODE = '22023';
    END IF;
    IF p_influencia_area IS NOT NULL AND (p_influencia_area < 0 OR p_influencia_area > 100) THEN
        RAISE EXCEPTION 'La influencia en el area (%%) debe estar entre 0 y 100' USING ERRCODE = '22023';
    END IF;
    IF p_numero_credito IS NOT NULL AND p_numero_credito < 0 THEN
        RAISE EXCEPTION 'El numero de creditos no puede ser negativo' USING ERRCODE = '22023';
    END IF;
    -- Si se cambia la asignatura: debe existir/activa y no duplicar en el plan.
    IF p_fk_asignatura IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_asignatura AND ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'La asignatura % no existe o esta inactiva', p_fk_asignatura USING ERRCODE = '23503';
        END IF;
        IF EXISTS (
            SELECT 1 FROM academico_test.TASIGNATURA_PLAN x
              JOIN academico_test.TASIGNATURA_PLAN cur ON cur.PK_TASIGNATURA_PLAN = p_pk
             WHERE x.FK_TPLAN = cur.FK_TPLAN AND x.PK_TASIGNATURA_PLAN <> p_pk
               AND x.FK_TASIGNATURA = p_fk_asignatura AND x.ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'La asignatura % ya esta en el plan de estudio de este grado', p_fk_asignatura
                USING ERRCODE = '23505';
        END IF;
    END IF;
    -- formato/criterio se setean SIEMPRE (permiten volver a NULL = heredar).
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
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TASIGNATURA_PLAN = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN RAISE EXCEPTION 'No existe un renglon de plan activo con PK %', p_pk USING ERRCODE = 'P0002'; END IF;
    RETURN p_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_eliminar(p_pk BIGINT, p_pk_usuario_solicitante BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
         WHERE ap.PK_TASIGNATURA_PLAN = p_pk));
    -- Bloqueo: la asignatura del renglon tiene asignaciones docente activas en
    -- algun grupo del grado del plan.
    IF EXISTS (
        SELECT 1
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
          JOIN academico_test.TGRUPO g ON g.FK_TGRADO = pl.FK_TGRADO AND g.ACTIVE = TRUE
          JOIN academico_test.TDOCENTE_ASIGNATURA da ON da.FK_TGRUPO = g.PK_TGRUPO
               AND da.FK_TASIGNATURA = ap.FK_TASIGNATURA AND da.ACTIVE = TRUE
         WHERE ap.PK_TASIGNATURA_PLAN = p_pk AND ap.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar: la asignatura tiene asignaciones academicas (docentes) en grupos del grado'
            USING ERRCODE = '23503';
    END IF;
    UPDATE academico_test.TASIGNATURA_PLAN SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TASIGNATURA_PLAN = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN RAISE EXCEPTION 'No existe un renglon de plan activo con PK %', p_pk USING ERRCODE = 'P0002'; END IF;
    -- Da de baja el enlace con el criterio de evaluacion.
    UPDATE academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TASIGNATURA_PLAN = p_pk AND ACTIVE = TRUE;
    RETURN p_pk;
END;
$$;

-- ---------------------------------------------------------------------------
-- fn_plan_soft_delete — baja logica del plan COMPLETO de un grado: el header
-- TPLAN + todos sus renglones TASIGNATURA_PLAN + sus enlaces al criterio de
-- evaluacion (TCRITERIO_EVALUACION_ASIGNATURA_PLAN). fn_plan_eliminar solo baja
-- un renglon y NO toca el header, por lo que el bloqueo del periodo por TPLAN
-- activo (V37) no se podia limpiar sin esta funcion. Bloquea si algun renglon
-- activo tiene asignaciones docente activas en grupos del grado (mismo criterio
-- que fn_plan_eliminar, generalizado al plan entero).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_plan_soft_delete(p_fk_grado BIGINT, p_pk_usuario_solicitante BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_pk_plan BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado));
    SELECT PK_TPLAN INTO v_pk_plan FROM academico_test.TPLAN
     WHERE FK_TGRADO = p_fk_grado AND ACTIVE = TRUE;
    IF v_pk_plan IS NULL THEN
        RAISE EXCEPTION 'No existe un plan de estudio activo para el grado %', p_fk_grado USING ERRCODE = 'P0002';
    END IF;
    -- Bloqueo: algun renglon del plan tiene asignaciones docente activas.
    IF EXISTS (
        SELECT 1
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TGRUPO g ON g.FK_TGRADO = p_fk_grado AND g.ACTIVE = TRUE
          JOIN academico_test.TDOCENTE_ASIGNATURA da ON da.FK_TGRUPO = g.PK_TGRUPO
               AND da.FK_TASIGNATURA = ap.FK_TASIGNATURA AND da.ACTIVE = TRUE
         WHERE ap.FK_TPLAN = v_pk_plan AND ap.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el plan del grado %: hay asignaturas con asignaciones academicas (docentes) activas', p_fk_grado
            USING ERRCODE = '23503';
    END IF;
    -- Enlaces al criterio de evaluacion de los renglones del plan.
    UPDATE academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE ACTIVE = TRUE AND FK_TASIGNATURA_PLAN IN (
         SELECT PK_TASIGNATURA_PLAN FROM academico_test.TASIGNATURA_PLAN
          WHERE FK_TPLAN = v_pk_plan AND ACTIVE = TRUE
     );
    -- Renglones del plan.
    UPDATE academico_test.TASIGNATURA_PLAN SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TPLAN = v_pk_plan AND ACTIVE = TRUE;
    -- Header del plan.
    UPDATE academico_test.TPLAN SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TPLAN = v_pk_plan AND ACTIVE = TRUE;
    RETURN v_pk_plan;
END;
$$;

-- Devuelve el valor EFECTIVO de formato/criterio-nota: el override del renglon
-- del plan si existe, si no lo heredado del criterio de evaluacion enlazado.
DROP FUNCTION IF EXISTS academico_test.fn_plan_listar(BIGINT, TEXT, INT, INT);
CREATE OR REPLACE FUNCTION academico_test.fn_plan_listar(
    p_fk_grado BIGINT, p_filtro TEXT DEFAULT NULL,
    p_page_index INT DEFAULT 0, p_page_size INT DEFAULT 10,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (codigo BIGINT, asignatura VARCHAR, intensidad_horaria NUMERIC, influencia_area NUMERIC,
               numero_creditos BIGINT, influye_desempeno BOOLEAN, matricula_obligatoria BOOLEAN,
               aprobacion_obligatoria BOOLEAN, formato_calificacion BIGINT, criterio_nota BIGINT,
               personalizado BOOLEAN, total_count BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT ap.PK_TASIGNATURA_PLAN, s.NOMBRE, ap.NUMERO_HORA, ap.INFLUENCIA_AREA, ap.NUMERO_CREDITO,
           (ap.INFLUYE_DESEMPLENO_ACADEMICO = 'S'), (ap.MATRICULA_OBLIGATORIA = 'S'),
           (ap.APROBACION_OBLIGATORIA = 'S'),
           COALESCE(ap.FK_TLV_FORMATO_CALIFICACION_DEF, ce.FK_TLV_FORMATO_CALIFICACION),
           COALESCE(ap.FK_TLV_CALCULO_DEFINITIVA,      ce.FK_TLV_MODIF_FINAL_PERACA),
           (ap.FK_TLV_FORMATO_CALIFICACION_DEF IS NOT NULL OR ap.FK_TLV_CALCULO_DEFINITIVA IS NOT NULL),
           count(*) OVER()::BIGINT
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN p        ON p.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TASIGNATURA s  ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA
      LEFT JOIN academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN cap
             ON cap.FK_TASIGNATURA_PLAN = ap.PK_TASIGNATURA_PLAN AND cap.ACTIVE = TRUE
      LEFT JOIN academico_test.TCRITERIO_EVALUACION ce
             ON ce.PK_TCRITERIO_EVALUACION = cap.FK_TCRITERIO_EVALUACION AND ce.ACTIVE = TRUE
     WHERE p.FK_TGRADO = p_fk_grado AND ap.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_filtro),'') IS NULL OR s.NOMBRE ILIKE '%' || p_filtro || '%')
     ORDER BY s.NOMBRE
     LIMIT NULLIF(p_page_size, 0)
    OFFSET COALESCE(p_page_index, 0) * COALESCE(NULLIF(p_page_size, 0), 0);
$$;

-- Detalle de un renglon del plan (para el formulario de edicion). Incluye el
-- id de la asignatura (para preseleccionar) y el valor EFECTIVO de
-- formato/criterio-nota (override del renglon o, si no hay, heredado del criterio).
DROP FUNCTION IF EXISTS academico_test.fn_plan_obtener(BIGINT);
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
      JOIN academico_test.TASIGNATURA s  ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA
      LEFT JOIN academico_test.TCRITERIO_EVALUACION_ASIGNATURA_PLAN cap
             ON cap.FK_TASIGNATURA_PLAN = ap.PK_TASIGNATURA_PLAN AND cap.ACTIVE = TRUE
      LEFT JOIN academico_test.TCRITERIO_EVALUACION ce
             ON ce.PK_TCRITERIO_EVALUACION = cap.FK_TCRITERIO_EVALUACION AND ce.ACTIVE = TRUE
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk AND ap.ACTIVE = TRUE;
$$;

-- Asignaturas del periodo del grado que todavia NO estan en su plan de estudio
-- (para el selector de "agregar asignatura al plan"). Evita ofrecer duplicados,
-- que ademas fn_plan_agregar rechaza.
DROP FUNCTION IF EXISTS academico_test.fn_plan_asignaturas_disponibles_listar(BIGINT, TEXT);
CREATE OR REPLACE FUNCTION academico_test.fn_plan_asignaturas_disponibles_listar(
    p_fk_grado BIGINT, p_filtro TEXT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, nombre VARCHAR, area_id BIGINT, area_nombre VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT s.PK_TASIGNATURA, s.NOMBRE, a.PK_TAREA, a.NOMBRE
      FROM academico_test.TGRADO g
      JOIN academico_test.TAREA a       ON a.FK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO AND a.ACTIVE = TRUE
      JOIN academico_test.TASIGNATURA s ON s.FK_TAREA = a.PK_TAREA AND s.ACTIVE = TRUE
     WHERE g.PK_TGRADO = p_fk_grado
       AND (NULLIF(TRIM(p_filtro),'') IS NULL OR s.NOMBRE ILIKE '%' || p_filtro || '%')
       AND NOT EXISTS (
             SELECT 1 FROM academico_test.TASIGNATURA_PLAN ap
               JOIN academico_test.TPLAN p ON p.PK_TPLAN = ap.FK_TPLAN
              WHERE p.FK_TGRADO = p_fk_grado AND ap.FK_TASIGNATURA = s.PK_TASIGNATURA AND ap.ACTIVE = TRUE)
     ORDER BY a.NOMBRE, s.NOMBRE;
$$;
