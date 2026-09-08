-- ===========================================================================
-- Criterio de Promoción — funciones consolidadas (última versión)
-- Generado: 2026-09-04
--
-- Migracion real, aplicada por Flyway en orden secuencial.
-- Su unico proposito es reunir en un solo lugar la version vigente de cada
-- funcion del modulo, ya que con el tiempo varias han sido redefinidas
-- (CREATE OR REPLACE FUNCTION) en migraciones posteriores.
--
-- Migraciones fuente consultadas:
--   - V39__promotion_criteria_module.sql
--   - V102__criterio_promocion_mensajes_error_con_nombre.sql
--
-- Verificacion: se corrio
--   grep -rn "FUNCTION academico_test.<nombre>(" postgres/migrations/
-- para fn_criterio_prom_guardar, fn_criterio_prom_obtener y
-- fn_nodo_curricular_listar; ninguna migracion posterior a V102/V39 las toca.
-- ===========================================================================

-- Fuente: V102__criterio_promocion_mensajes_error_con_nombre.sql
SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_guardar(p_fk_periodo bigint, p_fk_grado bigint DEFAULT NULL::bigint, p_nodo_curricular academico_test.nodo_curricular DEFAULT NULL::character varying, p_cantidad_nivelar numeric DEFAULT NULL::numeric, p_asignatura_obligatoria academico_test.bool_sn DEFAULT NULL::character varying, p_aprobacion_promedio academico_test.bool_sn DEFAULT NULL::character varying, p_desempenho_min_general numeric DEFAULT NULL::numeric, p_desempenho_minimo numeric DEFAULT NULL::numeric, p_max_asig_promedio numeric DEFAULT NULL::numeric, p_minimo_inasistencias numeric DEFAULT NULL::numeric, p_max_asig_nivelar_prom numeric DEFAULT NULL::numeric, p_obligatorias bigint[] DEFAULT NULL::bigint[], p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    d academico_test.TCRITERIO_PROMOCION;
    v_pk BIGINT; v_asig BIGINT; v_area BIGINT;
    v_nombre_asig VARCHAR(130); v_nombre_area VARCHAR(130);
    v_nombre_grado VARCHAR(130); v_establecimiento_id BIGINT;
BEGIN
    -- Autorizacion (CU-86e2w4xdt): capability fail-fast + scope por (EE, sede,
    -- jornada) del periodo academico. Wrapper sobre fn_assert_permiso_seccion.
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, NULL, NULL, NULL, 'EDITAR');
    IF p_fk_periodo IS NULL THEN
        RAISE EXCEPTION 'El periodo academico es obligatorio' USING ERRCODE = '22023';
    END IF;
    SELECT s.FK_TESTABLECIMIENTO INTO v_establecimiento_id
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_establecimiento_id,
        academico_test.fn_periodo_sede(p_fk_periodo),
        academico_test.fn_periodo_jornada(p_fk_periodo), 'EDITAR');
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

    IF p_fk_grado IS NOT NULL THEN
        SELECT NOMBRE INTO v_nombre_grado FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    END IF;
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        CASE WHEN p_fk_grado IS NULL
             THEN 'Configuración del criterio de promoción general del periodo'
             ELSE format('Configuración del criterio de promoción del grado %s', v_nombre_grado)
        END,
        v_establecimiento_id);

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
            CASE WHEN p_fk_grado IS NULL THEN 'S' ELSE 'N' END::academico_test.bool_sn, v_audit
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

    -- Areas/asignaturas obligatorias. Reescribe el set del criterio.
    -- p_nodo_curricular decide si los ids de p_obligatorias son de
    -- TASIGNATURA ('AS') o de TAREA ('AR') -- el lote es de un solo tipo,
    -- nunca mixto (asi lo arma el front, ver resolve-required-subjects.ts).
    IF p_obligatorias IS NOT NULL THEN
        UPDATE academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
           SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE FK_TCRITERIO_PROMOCION = v_id AND ACTIVE = TRUE;

        FOREACH v_pk IN ARRAY p_obligatorias
        LOOP
            v_asig := NULL; v_area := NULL;
            IF p_nodo_curricular = 'AS' THEN
                v_asig := v_pk;
                IF NOT EXISTS (
                    SELECT 1 FROM academico_test.TASIGNATURA s
                      JOIN academico_test.TAREA a ON a.PK_TAREA = s.FK_TAREA
                     WHERE s.PK_TASIGNATURA = v_asig AND s.ACTIVE = TRUE
                       AND a.FK_TPERIODO_ACADEMICO = p_fk_periodo
                ) THEN
                    SELECT s.NOMBRE INTO v_nombre_asig
                      FROM academico_test.TASIGNATURA s WHERE s.PK_TASIGNATURA = v_asig;
                    IF v_nombre_asig IS NOT NULL THEN
                        RAISE EXCEPTION 'La asignatura "%" no esta activa o no pertenece al periodo', v_nombre_asig
                            USING ERRCODE = '23503';
                    ELSE
                        RAISE EXCEPTION 'La asignatura no existe' USING ERRCODE = '23503';
                    END IF;
                END IF;
            ELSIF p_nodo_curricular = 'AR' THEN
                v_area := v_pk;
                IF NOT EXISTS (
                    SELECT 1 FROM academico_test.TAREA
                     WHERE PK_TAREA = v_area AND ACTIVE = TRUE
                       AND FK_TPERIODO_ACADEMICO = p_fk_periodo
                ) THEN
                    SELECT NOMBRE INTO v_nombre_area FROM academico_test.TAREA WHERE PK_TAREA = v_area;
                    IF v_nombre_area IS NOT NULL THEN
                        RAISE EXCEPTION 'El area "%" no esta activa o no pertenece al periodo', v_nombre_area
                            USING ERRCODE = '23503';
                    ELSE
                        RAISE EXCEPTION 'El area no existe' USING ERRCODE = '23503';
                    END IF;
                END IF;
            ELSE
                RAISE EXCEPTION 'nodo_curricular debe ser AS o AR para guardar obligatorias'
                    USING ERRCODE = '22023';
            END IF;
            -- Sin duplicados dentro del set.
            IF EXISTS (
                SELECT 1 FROM academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
                 WHERE FK_TCRITERIO_PROMOCION = v_id AND ACTIVE = TRUE
                   AND FK_TASIGNATURA IS NOT DISTINCT FROM v_asig
                   AND FK_TAREA IS NOT DISTINCT FROM v_area
            ) THEN
                IF v_asig IS NOT NULL THEN
                    SELECT NOMBRE INTO v_nombre_asig FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = v_asig;
                    RAISE EXCEPTION 'La asignatura "%" ya esta en la lista de obligatorias', v_nombre_asig
                        USING ERRCODE = '23505';
                ELSE
                    SELECT NOMBRE INTO v_nombre_area FROM academico_test.TAREA WHERE PK_TAREA = v_area;
                    RAISE EXCEPTION 'El area "%" ya esta en la lista de obligatorias', v_nombre_area
                        USING ERRCODE = '23505';
                END IF;
            END IF;
            INSERT INTO academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
                (FK_TCRITERIO_PROMOCION, FK_TASIGNATURA, FK_TAREA, CREATED_BY)
            VALUES (v_id, v_asig, v_area, v_audit);
        END LOOP;
    END IF;

    RETURN v_id;
END;
$function$
;

-- Fuente: V39__promotion_criteria_module.sql
CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_obtener(
    p_fk_periodo BIGINT DEFAULT NULL,
    p_fk_grado   BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT, academic_period_id BIGINT, grade_id BIGINT, curriculum_node nodo_curricular,
    max_failed_recovery NUMERIC, asignatura_obligatoria bool_sn, apply_average_approval bool_sn,
    base_percentage NUMERIC, minimum_subject_percentage NUMERIC, max_failed_for_average NUMERIC,
    absence_percentage NUMERIC, max_leveled_subjects NUMERIC, mandatory_subjects JSONB
)
LANGUAGE sql STABLE AS $$
    SELECT cp.PK_TCRITERIO_PROMOCION, cp.FK_TPERIODO_ACADEMICO, cp.FK_TGRADO,
           cp.NODO_CURRICULAR, cp.CANTIDAD_NIVELAR, cp.ASIGNATURA_OBLIGATORIA,
           cp.APROBACION_PROMEDIO, cp.DESEMPENHO_MINIMO_GENERAL, cp.DESEMPENHO_MINIMO,
           cp.MAX_ASIG_PROMEDIO, cp.MINIMO_INASISTENCIAS, cp.MAX_ASIG_NIVELAR_PROMOVIDO,
           -- Obligatorias del criterio (XOR asignatura/area). Para una asignatura,
           -- el area se deriva de TASIGNATURA.FK_TAREA (no se guarda por separado).
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                          'id', o.PK_TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA,
                          'type', CASE WHEN o.FK_TASIGNATURA IS NOT NULL THEN 'subject' ELSE 'area' END,
                          'subjectId', o.FK_TASIGNATURA,
                          'subjectName', s.NOMBRE,
                          'areaId', COALESCE(o.FK_TAREA, s.FK_TAREA),
                          'areaName', COALESCE(ar.NOMBRE, sar.NOMBRE))
                          ORDER BY o.PK_TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA)
                 FROM academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA o
                 LEFT JOIN academico_test.TASIGNATURA s ON s.PK_TASIGNATURA = o.FK_TASIGNATURA
                 LEFT JOIN academico_test.TAREA sar ON sar.PK_TAREA = s.FK_TAREA
                 LEFT JOIN academico_test.TAREA ar  ON ar.PK_TAREA = o.FK_TAREA
                WHERE o.FK_TCRITERIO_PROMOCION = cp.PK_TCRITERIO_PROMOCION AND o.ACTIVE = TRUE),
               '[]'::jsonb)
      FROM academico_test.TCRITERIO_PROMOCION cp
     WHERE cp.ACTIVE = TRUE
       AND academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante, cp.FK_TPERIODO_ACADEMICO)
       AND ( (p_fk_grado IS NOT NULL AND cp.FK_TGRADO = p_fk_grado)
          OR (p_fk_grado IS NULL AND cp.FK_TPERIODO_ACADEMICO = p_fk_periodo AND cp.FK_TGRADO IS NULL) );
$$;

-- Fuente: V39__promotion_criteria_module.sql
CREATE OR REPLACE FUNCTION academico_test.fn_nodo_curricular_listar(
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (key TEXT, label TEXT)
LANGUAGE sql IMMUTABLE AS $$
    SELECT * FROM (VALUES ('AS', 'Asignatura'), ('AR', 'Area')) AS t(key, label);
$$;
