-- PORCENTAJE_INICIAL_CALIF / PORCENTAJE_MAXIMO_RECUPERACION (TCRITERIO_EVALUACION)
-- deben guardar un PORCENTAJE (0-100), no la nota cruda en la escala del
-- formato -- lo confirma tanto el nombre de las columnas como
-- fn_criterio_eval_obtener (redefinida directo en la base, no versionada
-- hasta ahora), que al leer hace:
--   round(ce.PORCENTAJE_INICIAL_CALIF / 100 * CASE formato ... END, 2)
-- es decir, asume que el valor guardado ya es un porcentaje y lo reconvierte
-- a la escala del formato para mostrarlo.
--
-- El problema estaba en fn_criterio_eval_actualizar (V41/V79/V93/V95): nunca
-- hacia esa conversion al guardar, persistia tal cual el valor que manda el
-- front (ya en la escala del formato, ej. "5" para un formato "DE CERO A
-- CINCO"). Con la lectura asumiendo porcentaje, guardar "5" se mostraba como
-- "0.25" (5/100*5).
--
-- Fix: antes de guardar, p_initial_grade/p_max_recovery_grade se convierten a
-- porcentaje contra el formato EFECTIVO del criterio (el que se esta
-- seteando en este mismo UPDATE si p_grading_format viene, si no el que ya
-- tenia guardado) usando la misma tabla de equivalencias que ya usa
-- fn_criterio_eval_obtener para la conversion inversa -- si esa tabla cambia
-- alguna vez hay que mantener las dos en sync.

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_actualizar(
    p_pk_periodo                  BIGINT,

    p_grading_format              BIGINT DEFAULT NULL,
    p_grading_scale               BIGINT DEFAULT NULL,
    p_set_grading_scale           BOOLEAN DEFAULT FALSE,

    p_period_calc_elements        BIGINT DEFAULT NULL,

    p_modif_final_peraca          BIGINT DEFAULT NULL,
    p_subject_grade_criteria      BIGINT DEFAULT NULL,
    p_final_grade_criteria        BIGINT DEFAULT NULL,
    p_area_grade_criteria         BIGINT DEFAULT NULL,

    p_student_wo_grades            BIGINT DEFAULT NULL,

    p_rounding_mode                BIGINT DEFAULT NULL,

    p_initial_grade                NUMERIC DEFAULT NULL,
    p_max_recovery_grade           NUMERIC DEFAULT NULL,

    p_pk_usuario_solicitante       BIGINT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    v_n INT;
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_escala_actual BIGINT;
    -- FK_TESCALA resuelta a partir de p_grading_scale (PK_TESCALA_VALORACION).
    v_fk_tescala BIGINT;
    -- Formato efectivo (el nuevo si se esta cambiando, si no el ya guardado)
    -- y su nota maxima, para convertir initial_grade/max_recovery_grade a
    -- porcentaje antes de guardar.
    v_formato_id BIGINT;
    v_formato_nombre VARCHAR;
    v_formato_max NUMERIC;
    v_initial_pct NUMERIC;
    v_max_recovery_pct NUMERIC;
BEGIN

    -- Alcance por rol
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(p_pk_periodo)
    );

    /*
     * FK_TESCALA solo cambia cuando p_set_grading_scale = TRUE. p_grading_scale
     * es PK_TESCALA_VALORACION (la banda elegida en el picker), no PK_TESCALA.
     */
    IF p_set_grading_scale
       AND p_grading_scale IS NOT NULL
    THEN

        SELECT tv.FK_TESCALA
          INTO v_fk_tescala
          FROM academico_test.TESCALA_VALORACION tv
          JOIN academico_test.TESCALA t ON t.PK_TESCALA = tv.FK_TESCALA AND t.ACTIVE = TRUE
         WHERE tv.PK_TESCALA_VALORACION = p_grading_scale
           AND tv.ACTIVE = TRUE;

        IF v_fk_tescala IS NULL THEN
            RAISE EXCEPTION
                'La escala de valoracion % no existe o esta inactiva',
                p_grading_scale
                USING ERRCODE = '23503';
        END IF;

        -- La escala debe pertenecer al periodo
        IF NOT EXISTS (
            SELECT 1
            FROM academico_test.TNIVEL_ESCALA
            WHERE FK_TESCALA = v_fk_tescala
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

    /*
     * initial_grade/max_recovery_grade llegan en la escala del formato (ej.
     * "5" para "DE CERO A CINCO"), pero PORCENTAJE_INICIAL_CALIF /
     * PORCENTAJE_MAXIMO_RECUPERACION guardan un porcentaje -- se convierten
     * acá contra el formato EFECTIVO (el nuevo si se esta cambiando en este
     * mismo guardado, si no el que ya tenia el criterio). Misma tabla de
     * equivalencias que usa fn_criterio_eval_obtener para la conversion
     * inversa al leer.
     */
    IF p_initial_grade IS NOT NULL OR p_max_recovery_grade IS NOT NULL THEN
        SELECT COALESCE(p_grading_format, FK_TLV_FORMATO_CALIFICACION)
          INTO v_formato_id
          FROM academico_test.TCRITERIO_EVALUACION
         WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo
           AND ACTIVE = TRUE;

        SELECT NOMBRE INTO v_formato_nombre
          FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = v_formato_id;

        v_formato_max := CASE UPPER(TRIM(COALESCE(v_formato_nombre, '')))
                              WHEN 'DE CERO A CINCO' THEN 5
                              WHEN 'DE CERO A DIEZ' THEN 10
                              ELSE 100
                          END;

        IF p_initial_grade IS NOT NULL THEN
            v_initial_pct := ROUND(p_initial_grade / v_formato_max * 100, 2);
        END IF;

        IF p_max_recovery_grade IS NOT NULL THEN
            v_max_recovery_pct := ROUND(p_max_recovery_grade / v_formato_max * 100, 2);
        END IF;
    END IF;

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
                   THEN v_fk_tescala
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
                   v_initial_pct,
                   PORCENTAJE_INICIAL_CALIF
               ),

           PORCENTAJE_MAXIMO_RECUPERACION =
               COALESCE(
                   v_max_recovery_pct,
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
       AND v_fk_tescala IS DISTINCT FROM v_escala_actual
    THEN

        PERFORM academico_test.fn_escala_propagar(
            p_pk_periodo,
            v_fk_tescala,
            v_audit
        );

    END IF;

    RETURN p_pk_periodo;
END;
$$;
