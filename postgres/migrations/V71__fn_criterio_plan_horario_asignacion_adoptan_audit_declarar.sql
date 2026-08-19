-- V71 — adopta fn_audit_declarar en criterio de evaluación/promoción, plan de
-- estudio, horario y asignación docente
-- (docs/etiqueta-catalogo-funciones-fn.md §9/§14/§15/§16).

CREATE OR REPLACE FUNCTION academico_test.fn_asignacion_guardar(
    p_academic_period_id bigint, p_fk_funcionario bigint, p_subject_ids text[], p_pk_usuario_solicitante bigint
) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_func BIGINT; v_count INT := 0; v_pair TEXT; v_grupo BIGINT; v_asig BIGINT;
    v_establecimiento_id BIGINT := academico_test.fn_periodo_establecimiento(p_academic_period_id);
    v_func_nombre TEXT; v_periodo_nombre TEXT;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_establecimiento_id);

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_ACADEMICO
         WHERE PK_TPERIODO_ACADEMICO = p_academic_period_id AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El periodo academico % no existe o no esta activo', p_academic_period_id USING ERRCODE = '23503';
    END IF;

    SELECT f.PK_TFUNCIONARIO, TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
      INTO v_func, v_func_nombre
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE f.PK_TFUNCIONARIO = p_fk_funcionario AND f.ACTIVE = TRUE;
    IF v_func IS NULL THEN
        RAISE EXCEPTION 'No existe un funcionario con id %', p_fk_funcionario USING ERRCODE = '23503';
    END IF;
    SELECT NOMBRE INTO v_periodo_nombre FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_academic_period_id;

    PERFORM pg_advisory_xact_lock(hashtext('docasig:' || p_academic_period_id::text || ':' || v_func::text));

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Asignación académica del docente %s para el periodo %s', COALESCE(v_func_nombre, p_fk_funcionario::TEXT), v_periodo_nombre),
        v_establecimiento_id);

    UPDATE academico_test.TDOCENTE_ASIGNATURA
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TFUNCIONARIO = v_func AND FK_TPERIODO_ACADEMICO = p_academic_period_id AND ACTIVE = TRUE;

    IF p_subject_ids IS NOT NULL THEN
        FOREACH v_pair IN ARRAY p_subject_ids
        LOOP
            -- Formato "grupoId:asignaturaId" (ambos numericos).
            IF v_pair !~ '^[0-9]+:[0-9]+$' THEN
                RAISE EXCEPTION 'Identificador de asignacion invalido: %', v_pair USING ERRCODE = '22023';
            END IF;
            v_grupo := split_part(v_pair, ':', 1)::BIGINT;
            v_asig  := split_part(v_pair, ':', 2)::BIGINT;

            -- El par debe ser una combinacion valida del pool: grupo activo del
            -- periodo, y asignatura activa presente en el plan del grado del grupo.
            IF NOT EXISTS (
                SELECT 1
                  FROM academico_test.TGRUPO gr
                  JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO AND g.ACTIVE = TRUE
                       AND g.FK_TPERIODO_ACADEMICO = p_academic_period_id
                  JOIN academico_test.TPLAN pl ON pl.FK_TGRADO = g.PK_TGRADO AND pl.ACTIVE = TRUE
                  JOIN academico_test.TASIGNATURA_PLAN ap ON ap.FK_TPLAN = pl.PK_TPLAN
                       AND ap.FK_TASIGNATURA = v_asig AND ap.ACTIVE = TRUE
                  JOIN academico_test.TASIGNATURA s ON s.PK_TASIGNATURA = v_asig AND s.ACTIVE = TRUE
                 WHERE gr.PK_TGRUPO = v_grupo AND gr.ACTIVE = TRUE
            ) THEN
                RAISE EXCEPTION 'La asignatura % no corresponde al grupo % en el plan del periodo', v_asig, v_grupo
                    USING ERRCODE = '22023';
            END IF;

            -- Conflicto: la materia-grupo ya esta asignada a OTRO docente en el periodo.
            IF EXISTS (
                SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA
                 WHERE FK_TGRUPO = v_grupo AND FK_TASIGNATURA = v_asig
                   AND FK_TPERIODO_ACADEMICO = p_academic_period_id AND ACTIVE = TRUE
                   AND FK_TFUNCIONARIO <> v_func
            ) THEN
                RAISE EXCEPTION 'La asignatura % en el grupo % ya esta asignada a otro docente en el periodo', v_asig, v_grupo
                    USING ERRCODE = '23505';
            END IF;

            -- Duplicado dentro del mismo guardado (ya insertado en este loop).
            IF EXISTS (
                SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA
                 WHERE FK_TGRUPO = v_grupo AND FK_TASIGNATURA = v_asig
                   AND FK_TPERIODO_ACADEMICO = p_academic_period_id AND ACTIVE = TRUE
                   AND FK_TFUNCIONARIO = v_func
            ) THEN
                RAISE EXCEPTION 'La asignatura % en el grupo % esta duplicada en la asignacion', v_asig, v_grupo
                    USING ERRCODE = '23505';
            END IF;

            INSERT INTO academico_test.TDOCENTE_ASIGNATURA
                (FK_TGRUPO, FK_TFUNCIONARIO, FK_TASIGNATURA, FK_TPERIODO_ACADEMICO, CREATED_BY)
            VALUES (v_grupo, v_func, v_asig, p_academic_period_id, v_audit);
            v_count := v_count + 1;
        END LOOP;
    END IF;

    RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_actualizar(
    p_pk_periodo bigint, p_grading_format bigint DEFAULT NULL::bigint, p_grading_scale bigint DEFAULT NULL::bigint,
    p_set_grading_scale boolean DEFAULT false, p_period_calc_elements bigint DEFAULT NULL::bigint,
    p_modif_final_peraca bigint DEFAULT NULL::bigint, p_subject_grade_criteria bigint DEFAULT NULL::bigint,
    p_final_grade_criteria bigint DEFAULT NULL::bigint, p_area_grade_criteria bigint DEFAULT NULL::bigint,
    p_student_wo_grades bigint DEFAULT NULL::bigint, p_rounding_mode bigint DEFAULT NULL::bigint,
    p_initial_grade numeric DEFAULT NULL::numeric, p_max_recovery_grade numeric DEFAULT NULL::numeric,
    p_pk_usuario_solicitante bigint DEFAULT NULL::bigint
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_n INT;
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_escala_actual BIGINT;
    v_establecimiento_id BIGINT := academico_test.fn_periodo_establecimiento(p_pk_periodo);
    v_periodo_nombre TEXT;
BEGIN

    -- Alcance por rol
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_establecimiento_id);
    SELECT NOMBRE INTO v_periodo_nombre FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;

    /*
     * FK_TESCALA solo cambia cuando p_set_grading_scale = TRUE.
     */
    IF p_set_grading_scale
       AND p_grading_scale IS NOT NULL
    THEN

        IF NOT EXISTS (
            SELECT 1
            FROM academico_test.TESCALA
            WHERE PK_TESCALA = p_grading_scale
              AND ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION
                'La escala de valoracion % no existe o esta inactiva',
                p_grading_scale
                USING ERRCODE = '23503';
        END IF;

        -- La escala debe pertenecer al periodo
        IF NOT EXISTS (
            SELECT 1
            FROM academico_test.TNIVEL_ESCALA
            WHERE FK_TESCALA = p_grading_scale
              AND FK_PERIODO_ACADEMICO = p_pk_periodo
              AND ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION
                'La escala % no pertenece al periodo academico %',
                p_grading_scale,
                p_pk_periodo
                USING ERRCODE = '22023';
        END IF;

    END IF;

    /*
     * Cada FK_TLV_* debe resolver a una fila activa de TLISTA_VALOR de su
     * categoria correspondiente (cuando viene informado -- NULL siempre es
     * valido, significa "no tocar este campo").
     */
    IF p_grading_format IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_grading_format AND ACTIVE = TRUE
           AND CATEGORIA = 'FORMATO_CALIFICACION'
    ) THEN
        RAISE EXCEPTION 'El formato de calificacion % no existe o no es valido', p_grading_format
            USING ERRCODE = '23503';
    END IF;

    IF p_period_calc_elements IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_period_calc_elements AND ACTIVE = TRUE
           AND CATEGORIA = 'ELEMENTO_CALCULO_DEF'
    ) THEN
        RAISE EXCEPTION 'El elemento de calculo del periodo % no existe o no es valido', p_period_calc_elements
            USING ERRCODE = '23503';
    END IF;

    IF p_modif_final_peraca IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_modif_final_peraca AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El valor % no existe o esta inactivo en el catalogo', p_modif_final_peraca
            USING ERRCODE = '23503';
    END IF;

    IF p_subject_grade_criteria IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_subject_grade_criteria AND ACTIVE = TRUE
           AND CATEGORIA = 'TIPO_CALCULO'
    ) THEN
        RAISE EXCEPTION 'El criterio de calculo de la asignatura % no existe o no es valido', p_subject_grade_criteria
            USING ERRCODE = '23503';
    END IF;

    IF p_final_grade_criteria IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_final_grade_criteria AND ACTIVE = TRUE
           AND CATEGORIA = 'CRITERIO_FINAL_PERACA'
    ) THEN
        RAISE EXCEPTION 'El criterio de nota final % no existe o no es valido', p_final_grade_criteria
            USING ERRCODE = '23503';
    END IF;

    IF p_area_grade_criteria IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_area_grade_criteria AND ACTIVE = TRUE
           AND CATEGORIA = 'CRITERIO_AREA'
    ) THEN
        RAISE EXCEPTION 'El criterio de nota de area % no existe o no es valido', p_area_grade_criteria
            USING ERRCODE = '23503';
    END IF;

    IF p_student_wo_grades IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_student_wo_grades AND ACTIVE = TRUE
           AND CATEGORIA = 'DESEMPENIOSUGERIR'
    ) THEN
        RAISE EXCEPTION 'El desempeno sugerido sin calificacion % no existe o no es valido', p_student_wo_grades
            USING ERRCODE = '23503';
    END IF;

    IF p_rounding_mode IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_rounding_mode AND ACTIVE = TRUE
           AND CATEGORIA = 'MODO_REDONDEAR'
    ) THEN
        RAISE EXCEPTION 'El modo de redondeo % no existe o no es valido', p_rounding_mode
            USING ERRCODE = '23503';
    END IF;

    /*
     * Escala maestra actual para decidir si se debe propagar.
     */
    SELECT FK_TESCALA
      INTO v_escala_actual
      FROM academico_test.TCRITERIO_EVALUACION
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo
       AND ACTIVE = TRUE;

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Actualización del criterio de evaluación del periodo %s', v_periodo_nombre),
        v_establecimiento_id);

    /*
     * Actualizar criterio de evaluación.
     */
    UPDATE academico_test.TCRITERIO_EVALUACION
       SET
           FK_TLV_FORMATO_CALIFICACION =
               COALESCE(
                   p_grading_format,
                   FK_TLV_FORMATO_CALIFICACION
               ),

           FK_TESCALA =
               CASE
                   WHEN p_set_grading_scale
                   THEN p_grading_scale
                   ELSE FK_TESCALA
               END,

           FK_TLV_ELEMENTO_DEF =
               COALESCE(
                   p_period_calc_elements,
                   FK_TLV_ELEMENTO_DEF
               ),

           FK_TLV_MODIF_FINAL_PERACA =
               COALESCE(
                   p_modif_final_peraca,
                   FK_TLV_MODIF_FINAL_PERACA
               ),

           FK_TLV_CRITERIO_ASIGNATURA =
               COALESCE(
                   p_subject_grade_criteria,
                   FK_TLV_CRITERIO_ASIGNATURA
               ),

           FK_TLV_CRITERIO_FINAL =
               COALESCE(
                   p_final_grade_criteria,
                   FK_TLV_CRITERIO_FINAL
               ),

           FK_TLV_CRITERIO_AREA =
               COALESCE(
                   p_area_grade_criteria,
                   FK_TLV_CRITERIO_AREA
               ),

           FK_TLV_DESEMPENO_SIN_CALIF =
               COALESCE(
                   p_student_wo_grades,
                   FK_TLV_DESEMPENO_SIN_CALIF
               ),

           FK_TLV_MODO_REDONDEAR =
               COALESCE(
                   p_rounding_mode,
                   FK_TLV_MODO_REDONDEAR
               ),

           PORCENTAJE_INICIAL_CALIF =
               COALESCE(
                   p_initial_grade,
                   PORCENTAJE_INICIAL_CALIF
               ),

           PORCENTAJE_MAXIMO_RECUPERACION =
               COALESCE(
                   p_max_recovery_grade,
                   PORCENTAJE_MAXIMO_RECUPERACION
               ),

           MODIFIED_BY = v_audit,
           MODIFIED_AT = CURRENT_TIMESTAMP

     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo
       AND ACTIVE = TRUE;

    GET DIAGNOSTICS v_n = ROW_COUNT;

    IF v_n = 0 THEN
        RAISE EXCEPTION
            'No existe criterio de evaluacion activo para el periodo %',
            p_pk_periodo
            USING ERRCODE = 'P0002';
    END IF;

    /*
     * Solo propagar cuando se selecciona una escala diferente.
     */
    IF p_set_grading_scale
       AND p_grading_scale IS NOT NULL
       AND p_grading_scale IS DISTINCT FROM v_escala_actual
    THEN

        PERFORM academico_test.fn_escala_propagar(
            p_pk_periodo,
            p_grading_scale,
            v_audit
        );

    END IF;

    RETURN p_pk_periodo;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_prom_guardar(
    p_fk_periodo bigint, p_fk_grado bigint DEFAULT NULL::bigint,
    p_nodo_curricular academico_test.nodo_curricular DEFAULT NULL::character varying,
    p_cantidad_nivelar numeric DEFAULT NULL::numeric,
    p_asignatura_obligatoria academico_test.bool_sn DEFAULT NULL::character varying,
    p_aprobacion_promedio academico_test.bool_sn DEFAULT NULL::character varying,
    p_desempenho_min_general numeric DEFAULT NULL::numeric, p_desempenho_minimo numeric DEFAULT NULL::numeric,
    p_max_asig_promedio numeric DEFAULT NULL::numeric, p_minimo_inasistencias numeric DEFAULT NULL::numeric,
    p_max_asig_nivelar_prom numeric DEFAULT NULL::numeric, p_obligatorias bigint[] DEFAULT NULL::bigint[],
    p_pk_usuario_solicitante bigint DEFAULT NULL::bigint
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_id BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    d academico_test.TCRITERIO_PROMOCION;
    v_pk BIGINT; v_asig BIGINT; v_area BIGINT;
    v_establecimiento_id BIGINT; v_nombre_grado VARCHAR(130);
BEGIN
    -- Alcance por rol (como V37): gate grueso + gate fino por establecimiento.
    IF NOT academico_test.fn_periodo_usuario_puede_gestionar(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    IF p_fk_periodo IS NULL THEN
        RAISE EXCEPTION 'El periodo academico es obligatorio' USING ERRCODE = '22023';
    END IF;
    SELECT s.FK_TESTABLECIMIENTO INTO v_establecimiento_id
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo;
    IF NOT academico_test.fn_periodo_usuario_puede_escribir(p_pk_usuario_solicitante, v_establecimiento_id) THEN
        RAISE EXCEPTION 'El usuario no puede gestionar criterios de promocion de este establecimiento'
            USING ERRCODE = '42501';
    END IF;
    -- Ningun valor numerico puede ser negativo.
    IF p_cantidad_nivelar < 0 OR p_desempenho_min_general < 0 OR p_desempenho_minimo < 0
       OR p_max_asig_promedio < 0 OR p_minimo_inasistencias < 0 OR p_max_asig_nivelar_prom < 0 THEN
        RAISE EXCEPTION 'Los valores numericos del criterio de promocion no pueden ser negativos'
            USING ERRCODE = '22023';
    END IF;

    IF p_fk_grado IS NOT NULL THEN
        SELECT NOMBRE INTO v_nombre_grado FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    END IF;

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Configuración del criterio de promoción%s',
            CASE WHEN p_fk_grado IS NULL THEN ' general del periodo' ELSE format(' del grado %s', v_nombre_grado) END),
        v_establecimiento_id);

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
                    RAISE EXCEPTION 'La asignatura % no existe, esta inactiva o no pertenece al periodo', v_asig
                        USING ERRCODE = '23503';
                END IF;
            ELSIF p_nodo_curricular = 'AR' THEN
                v_area := v_pk;
                IF NOT EXISTS (
                    SELECT 1 FROM academico_test.TAREA
                     WHERE PK_TAREA = v_area AND ACTIVE = TRUE
                       AND FK_TPERIODO_ACADEMICO = p_fk_periodo
                ) THEN
                    RAISE EXCEPTION 'El area % no existe, esta inactiva o no pertenece al periodo', v_area
                        USING ERRCODE = '23503';
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

CREATE OR REPLACE FUNCTION academico_test.fn_horario_guardar(p_fk_grado bigint, p_entries jsonb, p_pk_usuario_solicitante bigint)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_max_bloques BIGINT; v_count INT := 0;
    v_bloque INT; v_grupo BIGINT; v_asig BIGINT; v_dia BIGINT; v_planitem BIGINT;
    entry jsonb;
    v_establecimiento_id BIGINT; v_grado_nombre VARCHAR(130);
BEGIN
    SELECT pa.BLOQUES_POR_DEFECTO, academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO), g.NOMBRE
      INTO v_max_bloques, v_establecimiento_id, v_grado_nombre
      FROM academico_test.TGRADO g JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
     WHERE g.PK_TGRADO = p_fk_grado AND g.ACTIVE = TRUE;
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_establecimiento_id);
    IF v_max_bloques IS NULL THEN
        RAISE EXCEPTION 'El grado % no existe o esta inactivo', p_fk_grado USING ERRCODE = '23503';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('horario:' || p_fk_grado::text));

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante, format('Configuración del horario del grado %s', v_grado_nombre), v_establecimiento_id);

    UPDATE academico_test.THORARIO h
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE h.ACTIVE = TRUE
       AND h.FK_TGRUPO IN (SELECT PK_TGRUPO FROM academico_test.TGRUPO WHERE FK_TGRADO = p_fk_grado);

    FOR entry IN SELECT * FROM jsonb_array_elements(COALESCE(p_entries, '[]'::jsonb))
    LOOP
        v_bloque   := (entry->>'bloque')::INT;
        v_grupo    := (entry->>'grupoId')::BIGINT;
        v_dia      := (entry->>'diaId')::BIGINT;
        v_planitem := (entry->>'planItemId')::BIGINT;
        -- Campos obligatorios de la celda.
        IF v_bloque IS NULL OR v_grupo IS NULL OR v_dia IS NULL OR v_planitem IS NULL THEN
            RAISE EXCEPTION 'Cada celda requiere grupoId, planItemId, diaId y bloque' USING ERRCODE = '22023';
        END IF;
        IF v_bloque < 0 OR v_bloque >= v_max_bloques THEN
            RAISE EXCEPTION 'Bloque % fuera de rango (0 a %)', v_bloque, v_max_bloques - 1 USING ERRCODE = '22023';
        END IF;
        -- El grupo pertenece al grado y esta activo.
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TGRUPO
             WHERE PK_TGRUPO = v_grupo AND FK_TGRADO = p_fk_grado AND ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'El grupo % no pertenece al grado % o esta inactivo', v_grupo, p_fk_grado USING ERRCODE = '22023';
        END IF;
        -- El dia debe ser del catalogo DIA_SEMANA.
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = v_dia AND ACTIVE = TRUE AND CATEGORIA = 'DIA_SEMANA'
        ) THEN
            RAISE EXCEPTION 'El dia % no es valido (debe ser de la categoria DIA_SEMANA)', v_dia USING ERRCODE = '23503';
        END IF;
        -- El renglon de plan debe existir, estar activo y pertenecer al plan del grado.
        SELECT ap.FK_TASIGNATURA INTO v_asig
          FROM academico_test.TASIGNATURA_PLAN ap
          JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN AND pl.ACTIVE = TRUE
         WHERE ap.PK_TASIGNATURA_PLAN = v_planitem AND ap.ACTIVE = TRUE
           AND pl.FK_TGRADO = p_fk_grado;
        IF v_asig IS NULL THEN
            RAISE EXCEPTION 'El renglon de plan % no existe, esta inactivo o no pertenece al grado %',
                v_planitem, p_fk_grado USING ERRCODE = '23503';
        END IF;
        -- Sin dos asignaturas en la misma casilla (grupo + dia + bloque). Como lo
        -- vigente ya se desactivo, cualquier ACTIVE=TRUE es de este mismo payload.
        IF EXISTS (
            SELECT 1 FROM academico_test.THORARIO
             WHERE FK_TGRUPO = v_grupo AND FK_TLV_DIA_SEMANA = v_dia
               AND NUMERO_BLOQUE = v_bloque AND ACTIVE = TRUE
        ) THEN
            RAISE EXCEPTION 'Celda duplicada: grupo %, dia %, bloque %', v_grupo, v_dia, v_bloque USING ERRCODE = '22023';
        END IF;
        INSERT INTO academico_test.THORARIO (NUMERO_BLOQUE, FK_TLV_DIA_SEMANA, FK_TGRUPO, FK_TASIGNATURA, CREATED_BY)
        VALUES (v_bloque, v_dia, v_grupo, v_asig, v_audit);
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_plan_actualizar(
    p_pk bigint, p_fk_asignatura bigint DEFAULT NULL::bigint, p_numero_hora numeric DEFAULT NULL::numeric,
    p_influencia_area numeric DEFAULT NULL::numeric, p_numero_credito bigint DEFAULT NULL::bigint,
    p_influye_desempeno boolean DEFAULT NULL::boolean, p_matricula_obligatoria boolean DEFAULT NULL::boolean,
    p_aprobacion_obligatoria boolean DEFAULT NULL::boolean, p_fk_formato_calif bigint DEFAULT NULL::bigint,
    p_fk_criterio_nota bigint DEFAULT NULL::bigint, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_establecimiento_id BIGINT; v_grado_nom VARCHAR(130); v_asignatura_nom VARCHAR(130);
BEGIN
    SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO), g.NOMBRE, s.NOMBRE
      INTO v_establecimiento_id, v_grado_nom, v_asignatura_nom
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
      JOIN academico_test.TASIGNATURA s ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk;
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_establecimiento_id);
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

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Actualización del plan de estudio: %s en %s', v_asignatura_nom, v_grado_nom),
        v_establecimiento_id);

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

CREATE OR REPLACE FUNCTION academico_test.fn_plan_agregar(
    p_fk_grado bigint, p_fk_asignatura bigint, p_numero_hora numeric, p_influencia_area numeric,
    p_numero_credito bigint, p_influye_desempeno boolean, p_matricula_obligatoria boolean,
    p_aprobacion_obligatoria boolean, p_fk_formato_calif bigint DEFAULT NULL::bigint,
    p_fk_criterio_nota bigint DEFAULT NULL::bigint, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_grado_nom TEXT; v_plan_id BIGINT; v_id BIGINT; v_periodo BIGINT;
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_establecimiento_id BIGINT; v_asignatura_nom TEXT;
BEGIN
    SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
      INTO v_establecimiento_id
      FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado;
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_establecimiento_id);
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
    SELECT NOMBRE INTO v_asignatura_nom FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_fk_asignatura AND ACTIVE = TRUE;
    IF v_asignatura_nom IS NULL THEN
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

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Asignación de %s al plan de estudio del grado %s', v_asignatura_nom, v_grado_nom),
        v_establecimiento_id);

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

CREATE OR REPLACE FUNCTION academico_test.fn_plan_eliminar(p_pk bigint, p_pk_usuario_solicitante bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_establecimiento_id BIGINT; v_grado_nom VARCHAR(130); v_asignatura_nom VARCHAR(130);
BEGIN
    SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO), g.NOMBRE, s.NOMBRE
      INTO v_establecimiento_id, v_grado_nom, v_asignatura_nom
      FROM academico_test.TASIGNATURA_PLAN ap
      JOIN academico_test.TPLAN pl ON pl.PK_TPLAN = ap.FK_TPLAN
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = pl.FK_TGRADO
      JOIN academico_test.TASIGNATURA s ON s.PK_TASIGNATURA = ap.FK_TASIGNATURA
     WHERE ap.PK_TASIGNATURA_PLAN = p_pk;
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_establecimiento_id);
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

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Eliminación de %s del plan de estudio de %s', COALESCE(v_asignatura_nom, p_pk::TEXT), v_grado_nom),
        v_establecimiento_id);

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

CREATE OR REPLACE FUNCTION academico_test.fn_plan_soft_delete(p_fk_grado bigint, p_pk_usuario_solicitante bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_pk_plan BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_establecimiento_id BIGINT; v_grado_nombre VARCHAR(130);
BEGIN
    SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO), g.NOMBRE
      INTO v_establecimiento_id, v_grado_nombre
      FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado;
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_establecimiento_id);
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

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante, format('Eliminación del plan de estudio completo del grado %s', v_grado_nombre),
        v_establecimiento_id);

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
