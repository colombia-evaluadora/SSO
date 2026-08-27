-- Modulo "criterio de evaluacion". Se confirmo en vivo (pg_proc) que existen
-- TRES overloads simultaneos y realmente desplegados de
-- academico_test.fn_criterio_eval_actualizar, no volcados historicos:
--   oid 39517 (12 args, con p_decimal_places/p_final_grade_editable)
--   oid 39651 (14 args, con p_modif_final_peraca/p_max_recovery_grade) -- esta
--             es la usada en produccion: public.query id_query=51 la llama
--             posicionalmente con esta firma de 14 args (evolucion V93/V95/V96).
--   oid 40148 (12 args, con p_pk_tescala_valoracion en vez de p_grading_scale)
-- Las tres siguen activas en pg_proc por compatibilidad con distintos
-- llamadores historicos, asi que se corrigen las tres. Cuerpo base tomado de
-- pg_get_functiondef en vivo (== a los volcados del scratchpad, confirmado
-- byte a byte).
--
-- fn_criterio_eval_obtener es LANGUAGE sql, solo SELECT, sin RAISE EXCEPTION
-- -- no se toca ni se incluye aqui.
--
-- Mensajes corregidos (mismo patron en las 3 firmas donde aplica):
--   "La escala de valoracion %/La valoracion % no existe o esta inactiva"
--     (regla 4): lookup del NOMBRE ignorando ACTIVE antes de fallar.
--   "La escala % no pertenece al periodo academico %" (regla 3: la escala ya
--     fue confirmada activa por el chequeo anterior): se usan los nombres de
--     TESCALA y TPERIODO_ACADEMICO.
--   Los catalogos TLISTA_VALOR de 39651 ("El formato de calificacion %/El
--     elemento de calculo... %/El valor %/El criterio... %/El desempeno...
--     %/El modo de redondeo % no existe o no es valido"): regla 4 -- lookup
--     por PK ignorando el filtro de categoria/active; si existe (con otra
--     categoria o inactivo) se muestra su nombre con un mensaje generico de
--     "no es valido para este campo"; si no existe en absoluto, mensaje
--     generico sin ID.
--   "No existe criterio de evaluacion activo para el periodo %" (regla 5):
--     lookup del NOMBRE del periodo ignorando ACTIVE.
--
-- Firmas, DEFAULTs, ERRCODEs y logica de negocio se preservan intactos.

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_actualizar(
    p_pk_periodo bigint,
    p_grading_format bigint DEFAULT NULL::bigint,
    p_grading_scale bigint DEFAULT NULL::bigint,
    p_set_grading_scale boolean DEFAULT false,
    p_period_calc_elements bigint DEFAULT NULL::bigint,
    p_modif_final_peraca bigint DEFAULT NULL::bigint,
    p_subject_grade_criteria bigint DEFAULT NULL::bigint,
    p_final_grade_criteria bigint DEFAULT NULL::bigint,
    p_area_grade_criteria bigint DEFAULT NULL::bigint,
    p_student_wo_grades bigint DEFAULT NULL::bigint,
    p_rounding_mode bigint DEFAULT NULL::bigint,
    p_initial_grade numeric DEFAULT NULL::numeric,
    p_max_recovery_grade numeric DEFAULT NULL::numeric,
    p_pk_usuario_solicitante bigint DEFAULT NULL::bigint
)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_n INT;
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_escala_actual BIGINT;
    v_fk_tescala BIGINT;
    v_formato_id BIGINT;
    v_formato_nombre VARCHAR;
    v_formato_max NUMERIC;
    v_initial_pct NUMERIC;
    v_max_recovery_pct NUMERIC;
    v_tmp_nombre VARCHAR;
    v_tmp_nombre2 VARCHAR;
    v_establecimiento_id BIGINT;
    v_periodo_nombre VARCHAR;
BEGIN
    v_establecimiento_id := academico_test.fn_periodo_establecimiento(p_pk_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        v_establecimiento_id
    );
    -- No habia una variable que resolviera el nombre del periodo sin
    -- condicion (v_tmp_nombre2 solo se llena en la rama de error de escala);
    -- se agrega para la etiqueta de auditoria.
    SELECT NOMBRE INTO v_periodo_nombre FROM academico_test.TPERIODO_ACADEMICO
     WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;

    IF p_set_grading_scale AND p_grading_scale IS NOT NULL THEN
        SELECT tv.FK_TESCALA
          INTO v_fk_tescala
          FROM academico_test.TESCALA_VALORACION tv
          JOIN academico_test.TESCALA t ON t.PK_TESCALA = tv.FK_TESCALA AND t.ACTIVE = TRUE
         WHERE tv.PK_TESCALA_VALORACION = p_grading_scale
           AND tv.ACTIVE = TRUE;

        IF v_fk_tescala IS NULL THEN
            SELECT v.NOMBRE INTO v_tmp_nombre
              FROM academico_test.TESCALA_VALORACION tv
              JOIN academico_test.TVALORACION v ON v.PK_TVALORACION = tv.FK_TVALORACION
             WHERE tv.PK_TESCALA_VALORACION = p_grading_scale;
            IF v_tmp_nombre IS NOT NULL THEN
                RAISE EXCEPTION 'La valoracion "%" existe pero esta inactiva', v_tmp_nombre
                    USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'La valoracion seleccionada no existe' USING ERRCODE = '23503';
            END IF;
        END IF;

        IF NOT EXISTS (
            SELECT 1
            FROM academico_test.TNIVEL_ESCALA
            WHERE FK_TESCALA = v_fk_tescala
              AND FK_PERIODO_ACADEMICO = p_pk_periodo
              AND ACTIVE = TRUE
        ) THEN
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TESCALA WHERE PK_TESCALA = v_fk_tescala;
            SELECT NOMBRE INTO v_tmp_nombre2 FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
            RAISE EXCEPTION 'La escala "%" no pertenece al periodo academico "%"',
                v_tmp_nombre, v_tmp_nombre2
                USING ERRCODE = '22023';
        END IF;
    END IF;

    IF p_grading_format IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_grading_format AND ACTIVE = TRUE
           AND CATEGORIA = 'FORMATO_CALIFICACION'
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_grading_format;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El formato de calificacion "%" no es valido para este campo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El formato de calificacion seleccionado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;

    IF p_period_calc_elements IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_period_calc_elements AND ACTIVE = TRUE
           AND CATEGORIA = 'ELEMENTO_CALCULO_DEF'
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_period_calc_elements;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El elemento de calculo del periodo "%" no es valido para este campo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El elemento de calculo del periodo seleccionado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;

    IF p_modif_final_peraca IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_modif_final_peraca AND ACTIVE = TRUE
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_modif_final_peraca;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El valor "%" existe pero esta inactivo en el catalogo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El valor seleccionado no existe en el catalogo' USING ERRCODE = '23503';
        END IF;
    END IF;

    IF p_subject_grade_criteria IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_subject_grade_criteria AND ACTIVE = TRUE
           AND CATEGORIA = 'TIPO_CALCULO'
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_subject_grade_criteria;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El criterio de calculo de la asignatura "%" no es valido para este campo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El criterio de calculo de la asignatura seleccionado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;

    IF p_final_grade_criteria IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_final_grade_criteria AND ACTIVE = TRUE
           AND CATEGORIA = 'CRITERIO_FINAL_PERACA'
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_final_grade_criteria;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El criterio de nota final "%" no es valido para este campo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El criterio de nota final seleccionado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;

    IF p_area_grade_criteria IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_area_grade_criteria AND ACTIVE = TRUE
           AND CATEGORIA = 'CRITERIO_AREA'
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_area_grade_criteria;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El criterio de nota de area "%" no es valido para este campo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El criterio de nota de area seleccionado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;

    IF p_student_wo_grades IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_student_wo_grades AND ACTIVE = TRUE
           AND CATEGORIA = 'DESEMPENIOSUGERIR'
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_student_wo_grades;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El desempeno sugerido sin calificacion "%" no es valido para este campo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El desempeno sugerido sin calificacion seleccionado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;

    IF p_rounding_mode IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_rounding_mode AND ACTIVE = TRUE
           AND CATEGORIA = 'MODO_REDONDEAR'
    ) THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_rounding_mode;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El modo de redondeo "%" no es valido para este campo', v_tmp_nombre
                USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El modo de redondeo seleccionado no existe' USING ERRCODE = '23503';
        END IF;
    END IF;

    SELECT FK_TESCALA
      INTO v_escala_actual
      FROM academico_test.TCRITERIO_EVALUACION
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo
       AND ACTIVE = TRUE;

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

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización del criterio de evaluación del periodo %s', v_periodo_nombre),
        v_establecimiento_id);

    UPDATE academico_test.TCRITERIO_EVALUACION
       SET
           FK_TLV_FORMATO_CALIFICACION = COALESCE(p_grading_format, FK_TLV_FORMATO_CALIFICACION),
           FK_TESCALA = CASE WHEN p_set_grading_scale THEN v_fk_tescala ELSE FK_TESCALA END,
           FK_TLV_ELEMENTO_DEF = COALESCE(p_period_calc_elements, FK_TLV_ELEMENTO_DEF),
           FK_TLV_MODIF_FINAL_PERACA = COALESCE(p_modif_final_peraca, FK_TLV_MODIF_FINAL_PERACA),
           FK_TLV_CRITERIO_ASIGNATURA = COALESCE(p_subject_grade_criteria, FK_TLV_CRITERIO_ASIGNATURA),
           FK_TLV_CRITERIO_FINAL = COALESCE(p_final_grade_criteria, FK_TLV_CRITERIO_FINAL),
           FK_TLV_CRITERIO_AREA = COALESCE(p_area_grade_criteria, FK_TLV_CRITERIO_AREA),
           FK_TLV_DESEMPENO_SIN_CALIF = COALESCE(p_student_wo_grades, FK_TLV_DESEMPENO_SIN_CALIF),
           FK_TLV_MODO_REDONDEAR = COALESCE(p_rounding_mode, FK_TLV_MODO_REDONDEAR),
           PORCENTAJE_INICIAL_CALIF = COALESCE(v_initial_pct, PORCENTAJE_INICIAL_CALIF),
           PORCENTAJE_MAXIMO_RECUPERACION = COALESCE(v_max_recovery_pct, PORCENTAJE_MAXIMO_RECUPERACION),
           MODIFIED_BY = v_audit,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo
       AND ACTIVE = TRUE;

    GET DIAGNOSTICS v_n = ROW_COUNT;

    IF v_n = 0 THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'No existe criterio de evaluacion activo para el periodo "%"', v_tmp_nombre
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'El periodo academico seleccionado no existe' USING ERRCODE = 'P0002';
        END IF;
    END IF;

    IF p_set_grading_scale AND p_grading_scale IS NOT NULL AND v_fk_tescala IS DISTINCT FROM v_escala_actual THEN
        PERFORM academico_test.fn_escala_propagar(p_pk_periodo, v_fk_tescala, v_audit);
    END IF;

    RETURN p_pk_periodo;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_actualizar(
    p_pk_periodo bigint,
    p_grading_format bigint DEFAULT NULL::bigint,
    p_grading_scale bigint DEFAULT NULL::bigint,
    p_set_grading_scale boolean DEFAULT false,
    p_period_calc_elements bigint DEFAULT NULL::bigint,
    p_subject_grade_criteria bigint DEFAULT NULL::bigint,
    p_final_grade_criteria bigint DEFAULT NULL::bigint,
    p_area_grade_criteria bigint DEFAULT NULL::bigint,
    p_student_wo_grades bigint DEFAULT NULL::bigint,
    p_rounding_mode numeric DEFAULT NULL::numeric,
    p_initial_grade numeric DEFAULT NULL::numeric,
    p_pk_usuario_solicitante bigint DEFAULT NULL::bigint,
    p_decimal_places numeric DEFAULT NULL::numeric,
    p_final_grade_editable bigint DEFAULT NULL::bigint,
    p_max_recovery_grade numeric DEFAULT NULL::numeric
)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_escala_actual BIGINT;
    v_fmt_nombre TEXT; v_max NUMERIC;
    v_tmp_nombre VARCHAR; v_tmp_nombre2 VARCHAR;
    v_establecimiento_id BIGINT;
    v_periodo_nombre VARCHAR;
BEGIN
    v_establecimiento_id := academico_test.fn_periodo_establecimiento(p_pk_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_establecimiento_id);
    -- No habia una variable que resolviera el nombre del periodo sin
    -- condicion; se agrega para la etiqueta de auditoria.
    SELECT NOMBRE INTO v_periodo_nombre FROM academico_test.TPERIODO_ACADEMICO
     WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
    SELECT lv.NOMBRE INTO v_fmt_nombre
      FROM academico_test.TLISTA_VALOR lv
     WHERE lv.PK_LISTA_VALOR = COALESCE(p_grading_format, (
         SELECT FK_TLV_FORMATO_CALIFICACION FROM academico_test.TCRITERIO_EVALUACION
          WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE
     ));
    v_max := CASE UPPER(TRIM(COALESCE(v_fmt_nombre, '')))
                WHEN 'DE CERO A CINCO' THEN 5
                WHEN 'DE CERO A DIEZ'  THEN 10
                ELSE 100
              END;
    IF p_set_grading_scale AND p_grading_scale IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TESCALA WHERE PK_TESCALA = p_grading_scale AND ACTIVE = TRUE
        ) THEN
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TESCALA WHERE PK_TESCALA = p_grading_scale;
            IF v_tmp_nombre IS NOT NULL THEN
                RAISE EXCEPTION 'La escala de valoracion "%" existe pero esta inactiva', v_tmp_nombre
                    USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'La escala de valoracion seleccionada no existe' USING ERRCODE = '23503';
            END IF;
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TNIVEL_ESCALA
             WHERE FK_TESCALA = p_grading_scale AND FK_PERIODO_ACADEMICO = p_pk_periodo AND ACTIVE = TRUE
        ) THEN
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TESCALA WHERE PK_TESCALA = p_grading_scale;
            SELECT NOMBRE INTO v_tmp_nombre2 FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
            RAISE EXCEPTION 'La escala "%" no pertenece al periodo academico "%"', v_tmp_nombre, v_tmp_nombre2
                USING ERRCODE = '22023';
        END IF;
    END IF;
    SELECT FK_TESCALA INTO v_escala_actual
      FROM academico_test.TCRITERIO_EVALUACION
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE;
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización del criterio de evaluación del periodo %s', v_periodo_nombre),
        v_establecimiento_id);

    UPDATE academico_test.TCRITERIO_EVALUACION SET
        FK_TLV_FORMATO_CALIFICACION = COALESCE(p_grading_format, FK_TLV_FORMATO_CALIFICACION),
        FK_TESCALA                  = CASE WHEN p_set_grading_scale THEN p_grading_scale ELSE FK_TESCALA END,
        FK_TLV_ELEMENTO_DEF         = COALESCE(p_period_calc_elements, FK_TLV_ELEMENTO_DEF),
        FK_TLV_CRITERIO_ASIGNATURA  = COALESCE(p_subject_grade_criteria, FK_TLV_CRITERIO_ASIGNATURA),
        FK_TLV_CRITERIO_FINAL       = COALESCE(p_final_grade_criteria, FK_TLV_CRITERIO_FINAL),
        FK_TLV_CRITERIO_AREA        = COALESCE(p_area_grade_criteria, FK_TLV_CRITERIO_AREA),
        FK_TLV_DESEMPENO_SIN_CALIF  = COALESCE(p_student_wo_grades, FK_TLV_DESEMPENO_SIN_CALIF),
        FK_TLV_MODO_REDONDEAR       = COALESCE(p_rounding_mode::BIGINT, FK_TLV_MODO_REDONDEAR),
        PORCENTAJE_INICIAL_CALIF    = COALESCE(p_initial_grade / v_max * 100, PORCENTAJE_INICIAL_CALIF),
        NUMERO_DECIMALES            = COALESCE(p_decimal_places, NUMERO_DECIMALES),
        FK_TLV_MODIF_FINAL_PERACA   = COALESCE(p_final_grade_editable, FK_TLV_MODIF_FINAL_PERACA),
        PORCENTAJE_MAXIMO_RECUPERACION = COALESCE(p_max_recovery_grade / v_max * 100, PORCENTAJE_MAXIMO_RECUPERACION),
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'No existe criterio de evaluacion activo para el periodo "%"', v_tmp_nombre
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'El periodo academico seleccionado no existe' USING ERRCODE = 'P0002';
        END IF;
    END IF;

    IF p_set_grading_scale AND p_grading_scale IS NOT NULL
       AND p_grading_scale IS DISTINCT FROM v_escala_actual THEN
        PERFORM academico_test.fn_escala_propagar(p_pk_periodo, p_grading_scale, v_audit);
    END IF;

    RETURN p_pk_periodo;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_criterio_eval_actualizar(
    p_pk_periodo bigint,
    p_grading_format bigint DEFAULT NULL::bigint,
    p_pk_tescala_valoracion bigint DEFAULT NULL::bigint,
    p_set_grading_scale boolean DEFAULT false,
    p_period_calc_elements bigint DEFAULT NULL::bigint,
    p_subject_grade_criteria bigint DEFAULT NULL::bigint,
    p_final_grade_criteria bigint DEFAULT NULL::bigint,
    p_area_grade_criteria bigint DEFAULT NULL::bigint,
    p_student_wo_grades bigint DEFAULT NULL::bigint,
    p_rounding_mode numeric DEFAULT NULL::numeric,
    p_initial_grade numeric DEFAULT NULL::numeric,
    p_pk_usuario_solicitante bigint DEFAULT NULL::bigint
)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_escala_actual BIGINT;
    v_grading_scale BIGINT;
    v_tmp_nombre VARCHAR; v_tmp_nombre2 VARCHAR;
    v_establecimiento_id BIGINT;
    v_periodo_nombre VARCHAR;
BEGIN
    v_establecimiento_id := academico_test.fn_periodo_establecimiento(p_pk_periodo);
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_establecimiento_id);
    -- No habia una variable que resolviera el nombre del periodo sin
    -- condicion; se agrega para la etiqueta de auditoria.
    SELECT NOMBRE INTO v_periodo_nombre FROM academico_test.TPERIODO_ACADEMICO
     WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;

    IF p_set_grading_scale AND p_pk_tescala_valoracion IS NOT NULL THEN
        SELECT FK_ESCALA INTO v_grading_scale
          FROM academico_test.TESCALA_VALORACION
         WHERE PK_TESCALA_VALORACION = p_pk_tescala_valoracion AND ACTIVE = TRUE;

        IF v_grading_scale IS NULL THEN
            SELECT v.NOMBRE INTO v_tmp_nombre
              FROM academico_test.TESCALA_VALORACION tv
              JOIN academico_test.TVALORACION v ON v.PK_TVALORACION = tv.FK_TVALORACION
             WHERE tv.PK_TESCALA_VALORACION = p_pk_tescala_valoracion;
            IF v_tmp_nombre IS NOT NULL THEN
                RAISE EXCEPTION 'La valoracion "%" existe pero esta inactiva', v_tmp_nombre
                    USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'La valoracion seleccionada no existe' USING ERRCODE = '23503';
            END IF;
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TESCALA WHERE PK_TESCALA = v_grading_scale AND ACTIVE = TRUE
        ) THEN
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TESCALA WHERE PK_TESCALA = v_grading_scale;
            IF v_tmp_nombre IS NOT NULL THEN
                RAISE EXCEPTION 'La escala de valoracion "%" existe pero esta inactiva', v_tmp_nombre
                    USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'La escala de valoracion seleccionada no existe' USING ERRCODE = '23503';
            END IF;
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM academico_test.TNIVEL_ESCALA
             WHERE FK_TESCALA = v_grading_scale AND FK_PERIODO_ACADEMICO = p_pk_periodo AND ACTIVE = TRUE
        ) THEN
            SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TESCALA WHERE PK_TESCALA = v_grading_scale;
            SELECT NOMBRE INTO v_tmp_nombre2 FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
            RAISE EXCEPTION 'La escala "%" no pertenece al periodo academico "%"', v_tmp_nombre, v_tmp_nombre2
                USING ERRCODE = '22023';
        END IF;
    END IF;

    SELECT FK_TESCALA INTO v_escala_actual
      FROM academico_test.TCRITERIO_EVALUACION
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE;

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización del criterio de evaluación del periodo %s', v_periodo_nombre),
        v_establecimiento_id);

    UPDATE academico_test.TCRITERIO_EVALUACION SET
        FK_TLV_FORMATO_CALIFICACION = COALESCE(p_grading_format, FK_TLV_FORMATO_CALIFICACION),
        FK_TESCALA                  = CASE WHEN p_set_grading_scale THEN v_grading_scale ELSE FK_TESCALA END,
        FK_TLV_ELEMENTO_DEF         = COALESCE(p_period_calc_elements, FK_TLV_ELEMENTO_DEF),
        FK_TLV_MODIF_FINAL_PERACA   = COALESCE(p_subject_grade_criteria, FK_TLV_MODIF_FINAL_PERACA),
        FK_TLV_CRITERIO_FINAL       = COALESCE(p_final_grade_criteria, FK_TLV_CRITERIO_FINAL),
        FK_TLV_CRITERIO_AREA        = COALESCE(p_area_grade_criteria, FK_TLV_CRITERIO_AREA),
        FK_TLV_DESEMPENO_SIN_CALIF  = COALESCE(p_student_wo_grades, FK_TLV_DESEMPENO_SIN_CALIF),
        NUMERO_DECIMALES            = COALESCE(p_rounding_mode, NUMERO_DECIMALES),
        PORCENTAJE_INICIAL_CALIF    = COALESCE(p_initial_grade, PORCENTAJE_INICIAL_CALIF),
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TCRITERIO_EVALUACION = p_pk_periodo AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        SELECT NOMBRE INTO v_tmp_nombre FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
        IF v_tmp_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'No existe criterio de evaluacion activo para el periodo "%"', v_tmp_nombre
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'El periodo academico seleccionado no existe' USING ERRCODE = 'P0002';
        END IF;
    END IF;

    IF p_set_grading_scale AND v_grading_scale IS NOT NULL
       AND v_grading_scale IS DISTINCT FROM v_escala_actual THEN
        PERFORM academico_test.fn_escala_propagar(p_pk_periodo, v_grading_scale, v_audit);
    END IF;

    RETURN p_pk_periodo;
END;
$$;
