-- ===========================================================================
-- V39 — Modulo de Criterio de Promocion (academico_test).
-- Un criterio por defecto del periodo (FK_TGRADO NULL) que aplica a todos los
-- grados; un override por grado (FK_TGRADO no NULL). POR_DEFECTO se deriva de
-- si FK_TGRADO es NULL. Hijo: TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
-- (XOR asignatura/area).
-- ===========================================================================

SET search_path TO academico_test, public;

-- Crear/actualizar el criterio (upsert por periodo-default o por grado).
-- Si p_fk_grado es NULL -> default del periodo; si no -> override del grado.
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_guardar(
    p_fk_periodo              BIGINT,
    p_fk_grado               BIGINT      DEFAULT NULL,
    p_nodo_curricular        nodo_curricular DEFAULT NULL,
    p_cantidad_nivelar       NUMERIC     DEFAULT NULL,
    p_asignatura_obligatoria bool_sn     DEFAULT NULL,
    p_aprobacion_promedio    bool_sn     DEFAULT NULL,
    p_desempenho_min_general NUMERIC     DEFAULT NULL,
    p_desempenho_minimo      NUMERIC     DEFAULT NULL,
    p_max_asig_promedio      NUMERIC     DEFAULT NULL,
    p_minimo_inasistencias   NUMERIC     DEFAULT NULL,
    p_max_asig_nivelar_prom  NUMERIC     DEFAULT NULL,
    -- Areas/asignaturas obligatorias (XOR por elemento). NULL = no tocar;
    -- [] = limpiar; [{asignaturaId?},{areaId?},...] = reescribir el set.
    p_obligatorias           jsonb       DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT      DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_id BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    d academico_test.TCRITERIO_PROMOCION;
    it jsonb; v_asig BIGINT; v_area BIGINT;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    IF p_fk_periodo IS NULL THEN
        RAISE EXCEPTION 'El periodo academico es obligatorio' USING ERRCODE = '22023';
    END IF;
    -- Ningun valor numerico puede ser negativo.
    IF p_cantidad_nivelar < 0 OR p_desempenho_min_general < 0 OR p_desempenho_minimo < 0
       OR p_max_asig_promedio < 0 OR p_minimo_inasistencias < 0 OR p_max_asig_nivelar_prom < 0 THEN
        RAISE EXCEPTION 'Los valores numericos del criterio de promocion no pueden ser negativos'
            USING ERRCODE = '22023';
    END IF;

    -- Buscar la fila existente (default del periodo o override del grado).
    IF p_fk_grado IS NULL THEN
        SELECT PK_TCRITERIO_PROMOCION INTO v_id FROM academico_test.TCRITERIO_PROMOCION
         WHERE FK_TPERIODO_ACADEMICO = p_fk_periodo AND FK_TGRADO IS NULL AND ACTIVE = TRUE;
    ELSE
        SELECT PK_TCRITERIO_PROMOCION INTO v_id FROM academico_test.TCRITERIO_PROMOCION
         WHERE FK_TGRADO = p_fk_grado AND ACTIVE = TRUE;
    END IF;

    IF v_id IS NULL THEN
        -- Override de un grado: hereda del criterio por defecto del periodo lo que
        -- no venga en los parametros (red de seguridad ante un guardado parcial).
        -- Para el default (p_fk_grado NULL), d queda vacio (NULLs) y no altera nada.
        IF p_fk_grado IS NOT NULL THEN
            SELECT * INTO d FROM academico_test.TCRITERIO_PROMOCION
             WHERE FK_TPERIODO_ACADEMICO = p_fk_periodo AND FK_TGRADO IS NULL AND ACTIVE = TRUE;
        END IF;
        INSERT INTO academico_test.TCRITERIO_PROMOCION (
            FK_TPERIODO_ACADEMICO, FK_TGRADO, NODO_CURRICULAR, CANTIDAD_NIVELAR,
            ASIGNATURA_OBLIGATORIA, APROBACION_PROMEDIO, DESEMPENHO_MINIMO_GENERAL,
            DESEMPENHO_MINIMO, MAX_ASIG_PROMEDIO, MINIMO_INASISTENCIAS,
            MAX_ASIG_NIVELAR_PROMOVIDO, POR_DEFECTO, CREATED_BY
        ) VALUES (
            p_fk_periodo, p_fk_grado,
            COALESCE(p_nodo_curricular, d.NODO_CURRICULAR),
            COALESCE(p_cantidad_nivelar, d.CANTIDAD_NIVELAR, 0),
            COALESCE(p_asignatura_obligatoria, d.ASIGNATURA_OBLIGATORIA),
            COALESCE(p_aprobacion_promedio, d.APROBACION_PROMEDIO),
            COALESCE(p_desempenho_min_general, d.DESEMPENHO_MINIMO_GENERAL),
            COALESCE(p_desempenho_minimo, d.DESEMPENHO_MINIMO),
            COALESCE(p_max_asig_promedio, d.MAX_ASIG_PROMEDIO),
            COALESCE(p_minimo_inasistencias, d.MINIMO_INASISTENCIAS),
            COALESCE(p_max_asig_nivelar_prom, d.MAX_ASIG_NIVELAR_PROMOVIDO),
            CASE WHEN p_fk_grado IS NULL THEN 'S' ELSE 'N' END::bool_sn, v_audit
        )
        RETURNING PK_TCRITERIO_PROMOCION INTO v_id;
    ELSE
        UPDATE academico_test.TCRITERIO_PROMOCION SET
            NODO_CURRICULAR = COALESCE(p_nodo_curricular, NODO_CURRICULAR),
            CANTIDAD_NIVELAR = COALESCE(p_cantidad_nivelar, CANTIDAD_NIVELAR),
            ASIGNATURA_OBLIGATORIA = COALESCE(p_asignatura_obligatoria, ASIGNATURA_OBLIGATORIA),
            APROBACION_PROMEDIO = COALESCE(p_aprobacion_promedio, APROBACION_PROMEDIO),
            DESEMPENHO_MINIMO_GENERAL = COALESCE(p_desempenho_min_general, DESEMPENHO_MINIMO_GENERAL),
            DESEMPENHO_MINIMO = COALESCE(p_desempenho_minimo, DESEMPENHO_MINIMO),
            MAX_ASIG_PROMEDIO = COALESCE(p_max_asig_promedio, MAX_ASIG_PROMEDIO),
            MINIMO_INASISTENCIAS = COALESCE(p_minimo_inasistencias, MINIMO_INASISTENCIAS),
            MAX_ASIG_NIVELAR_PROMOVIDO = COALESCE(p_max_asig_nivelar_prom, MAX_ASIG_NIVELAR_PROMOVIDO),
            MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TCRITERIO_PROMOCION = v_id;
    END IF;

    -- Areas/asignaturas obligatorias (XOR). Reescribe el set del criterio.
    IF p_obligatorias IS NOT NULL THEN
        UPDATE academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
           SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TCRITERIO_PROMOCION = v_id AND ACTIVE = TRUE;

        FOR it IN SELECT * FROM jsonb_array_elements(p_obligatorias)
        LOOP
            v_asig := NULLIF(it->>'asignaturaId','')::BIGINT;
            v_area := NULLIF(it->>'areaId','')::BIGINT;
            IF (v_asig IS NULL) = (v_area IS NULL) THEN
                RAISE EXCEPTION 'Cada obligatoria debe indicar exactamente una asignatura o una area'
                    USING ERRCODE = '22023';
            END IF;
            IF v_asig IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = v_asig AND ACTIVE = TRUE
            ) THEN
                RAISE EXCEPTION 'La asignatura % no existe o esta inactiva', v_asig USING ERRCODE = '23503';
            END IF;
            IF v_area IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM academico_test.TAREA WHERE PK_TAREA = v_area AND ACTIVE = TRUE
            ) THEN
                RAISE EXCEPTION 'El area % no existe o esta inactiva', v_area USING ERRCODE = '23503';
            END IF;
            -- Sin duplicados dentro del set.
            IF EXISTS (
                SELECT 1 FROM academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
                 WHERE FK_TCRITERIO_PROMOCION = v_id AND ACTIVE = TRUE
                   AND FK_TASIGNATURA IS NOT DISTINCT FROM v_asig
                   AND FK_TAREA IS NOT DISTINCT FROM v_area
            ) THEN
                RAISE EXCEPTION 'Obligatoria duplicada (asignatura % / area %)', v_asig, v_area USING ERRCODE = '23505';
            END IF;
            INSERT INTO academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
                (FK_TCRITERIO_PROMOCION, FK_TASIGNATURA, FK_TAREA, CREATED_BY)
            VALUES (v_id, v_asig, v_area, v_audit);
        END LOOP;
    END IF;

    RETURN v_id;
END;
$$;

-- Lectura: criterio por periodo (default) o por grado (override).
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_obtener(
    p_fk_periodo BIGINT DEFAULT NULL,
    p_fk_grado   BIGINT DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT, academic_period_id BIGINT, grade_id BIGINT, curriculum_node nodo_curricular,
    max_failed_recovery NUMERIC, asignatura_obligatoria bool_sn, apply_average_approval bool_sn,
    base_percentage NUMERIC, minimum_subject_percentage NUMERIC, max_failed_for_average NUMERIC,
    absence_percentage NUMERIC, max_leveled_subjects NUMERIC
)
LANGUAGE sql STABLE AS $$
    SELECT cp.PK_TCRITERIO_PROMOCION, cp.FK_TPERIODO_ACADEMICO, cp.FK_TGRADO,
           cp.NODO_CURRICULAR, cp.CANTIDAD_NIVELAR, cp.ASIGNATURA_OBLIGATORIA,
           cp.APROBACION_PROMEDIO, cp.DESEMPENHO_MINIMO_GENERAL, cp.DESEMPENHO_MINIMO,
           cp.MAX_ASIG_PROMEDIO, cp.MINIMO_INASISTENCIAS, cp.MAX_ASIG_NIVELAR_PROMOVIDO
      FROM academico_test.TCRITERIO_PROMOCION cp
     WHERE cp.ACTIVE = TRUE
       AND ( (p_fk_grado IS NOT NULL AND cp.FK_TGRADO = p_fk_grado)
          OR (p_fk_grado IS NULL AND cp.FK_TPERIODO_ACADEMICO = p_fk_periodo AND cp.FK_TGRADO IS NULL) );
$$;

-- Areas/asignaturas obligatorias del criterio (XOR asignatura/area).
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_asig_agregar(
    p_fk_criterio   BIGINT,
    p_fk_asignatura BIGINT DEFAULT NULL,
    p_fk_area       BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    IF (p_fk_asignatura IS NULL) = (p_fk_area IS NULL) THEN
        RAISE EXCEPTION 'Debe indicar exactamente una asignatura o una area, no ambas ni ninguna'
            USING ERRCODE = '22023';
    END IF;
    -- El criterio debe existir y estar activo.
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TCRITERIO_PROMOCION
         WHERE PK_TCRITERIO_PROMOCION = p_fk_criterio AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El criterio de promocion % no existe o esta inactivo', p_fk_criterio USING ERRCODE = '23503';
    END IF;
    -- La asignatura o el area (segun corresponda) debe existir y estar activa.
    IF p_fk_asignatura IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_asignatura AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'La asignatura % no existe o esta inactiva', p_fk_asignatura USING ERRCODE = '23503';
    END IF;
    IF p_fk_area IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TAREA WHERE PK_TAREA = p_fk_area AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El area % no existe o esta inactiva', p_fk_area USING ERRCODE = '23503';
    END IF;
    -- Sin duplicados: misma asignatura/area activa para el mismo criterio.
    IF EXISTS (
        SELECT 1 FROM academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
         WHERE FK_TCRITERIO_PROMOCION = p_fk_criterio AND ACTIVE = TRUE
           AND FK_TASIGNATURA IS NOT DISTINCT FROM p_fk_asignatura
           AND FK_TAREA IS NOT DISTINCT FROM p_fk_area
    ) THEN
        RAISE EXCEPTION 'Esa asignatura/area ya esta registrada para el criterio %', p_fk_criterio
            USING ERRCODE = '23505';
    END IF;
    INSERT INTO academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
        (FK_TCRITERIO_PROMOCION, FK_TASIGNATURA, FK_TAREA, CREATED_BY)
    VALUES (p_fk_criterio, p_fk_asignatura, p_fk_area, v_audit)
    RETURNING PK_TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA INTO v_id;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_asig_eliminar(
    p_pk BIGINT, p_pk_usuario_solicitante BIGINT
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    UPDATE academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN RAISE EXCEPTION 'No existe (activa) con PK %', p_pk USING ERRCODE = 'P0002'; END IF;
    RETURN p_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_asig_listar(p_fk_criterio BIGINT)
RETURNS TABLE (id BIGINT, promotion_criteria_id BIGINT, subject_id BIGINT, area_id BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT PK_TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA, FK_TCRITERIO_PROMOCION,
           FK_TASIGNATURA, FK_TAREA
      FROM academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
     WHERE FK_TCRITERIO_PROMOCION = p_fk_criterio AND ACTIVE = TRUE;
$$;
