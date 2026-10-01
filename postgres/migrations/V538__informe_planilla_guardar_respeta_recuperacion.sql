-- ===========================================================================
-- V538 - Consolidar desde la planilla no pisa una recuperacion de NOTA_FINAL.
--
--   fn_informe_planilla_guardar, lo mismo que V537 para una asignatura:
--     - escribe con fn_informe_nota_periodo_escribir_interno (V536).
--     - sin_cambio compara contra la BASE cuando hay recuperacion.
--     - NOTA_ANTERIOR y NOTA_GUARDADA siguen siendo la base: el retorno no
--       cambia de forma (no se agrega columna para no tener que hacer DROP
--       del endpoint de la planilla en esta tanda).
--
-- Depende de: V490 (ultimo cuerpo), V536.
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_informe_planilla_guardar(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_tasignatura bigint, p_fk_tperiodo_evaluacion bigint, p_fk_tmatriculas bigint[] DEFAULT NULL::bigint[])
 RETURNS TABLE(fk_tmatricula bigint, estudiante character varying, resultado character varying, nota_anterior numeric, nota_guardada numeric, promedio_periodo numeric, aprobadas bigint, reprobadas bigint)
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
DECLARE
    v_fk_grado   BIGINT;
    v_fk_peraca  BIGINT;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_pe_peraca  BIGINT;
    r_mat        RECORD;
    v_proy       NUMERIC;
    v_prev       NUMERIC;
    v_existe     BOOLEAN;
    v_res        VARCHAR;
    v_m          RECORD;
    v_hist       JSONB := '[]'::JSONB;
BEGIN
    SELECT gd.PK_TGRADO, gd.FK_TPERIODO_ACADEMICO,
           s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_grado, v_fk_peraca, v_fk_sede, v_fk_jornada, v_fk_ee
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE gr.PK_TGRUPO = p_fk_tgrupo
       AND gr.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el grupo solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_planilla_grupo_asignatura_assert(
        p_fk_tgrupo, p_fk_tasignatura, v_fk_grado);

    SELECT pe.FK_TPERIODO_ACADEMICO
      INTO v_pe_peraca
      FROM academico_test.TPERIODO_EVALUACION pe
     WHERE pe.PK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
       AND pe.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el periodo de evaluacion solicitado'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_pe_peraca IS DISTINCT FROM v_fk_peraca THEN
        RAISE EXCEPTION 'El periodo de evaluacion no pertenece al periodo academico del grupo'
            USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'EDITAR',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    -- V490 -- el recorte por grupo, DESPUES del gate de arriba. Para
    -- quien alcanza la sede entera es un no-op.
    PERFORM academico_test.fn_informe_assert_grupo_propio(
        p_pk_usuario_solicitante, p_fk_tgrupo);

    FOR r_mat IN
        SELECT m.PK_TMATRICULA AS pk,
               NULLIF(TRIM(CONCAT_WS(' ', u.PRIMER_NOMBRE, u.PRIMER_APELLIDO)), '')::VARCHAR AS nombre
          FROM academico_test.TMATRICULA m
          LEFT JOIN academico_test.TESTUDIANTE es ON es.PK_TESTUDIANTE = m.FK_TESTUDIANTE
          LEFT JOIN academico_test.TUSUARIO u     ON u.PK_TUSUARIO     = es.FK_TUSUARIO
         WHERE m.FK_TGRUPO = p_fk_tgrupo
           AND m.ACTIVE = TRUE
           AND (p_fk_tmatriculas IS NULL
                OR CARDINALITY(p_fk_tmatriculas) = 0
                OR m.PK_TMATRICULA = ANY (p_fk_tmatriculas))
         ORDER BY 2, 1
    LOOP
        v_proy := academico_test.fn_asignatura_definitiva_proyectada_periodo(
                      r_mat.pk, p_fk_tasignatura, p_fk_tperiodo_evaluacion);

        -- V538 -- con recuperacion de NOTA_FINAL lo comparable con la
        -- proyectada es la ORIGINAL (CALIFICACION), no la resultante.
        SELECT CASE WHEN sn.RECUPERACION IS NOT NULL AND sn.DEFINITIVA IS NOT NULL
                        THEN sn.CALIFICACION ELSE sn.DEFINITIVA END, TRUE
          INTO v_prev, v_existe
          FROM academico_test.TASIGNATURA_NOTA sn
         WHERE sn.FK_TMATRICULA          = r_mat.pk
           AND sn.FK_TASIGNATURA         = p_fk_tasignatura
           AND sn.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
           AND sn.ACTIVE = TRUE;

        IF v_proy IS NULL THEN
            v_res := 'sin_proyeccion';
        ELSIF COALESCE(v_existe, FALSE) AND v_prev = v_proy THEN
            v_res := 'sin_cambio';
        ELSE
            -- V538 -- escritura unica: con recuperacion de NOTA_FINAL la
            -- proyectada pasa a ser la base y la definitiva se recombina.
            PERFORM academico_test.fn_informe_nota_periodo_escribir_interno(
                        p_pk_usuario_solicitante, r_mat.pk, p_fk_tasignatura,
                        p_fk_tperiodo_evaluacion, v_proy);

            v_res := CASE WHEN COALESCE(v_existe, FALSE) THEN 'actualizada'
                          ELSE 'guardada' END;
        END IF;

        PERFORM academico_test.fn_informe_metricas_recalcular(
            p_pk_usuario_solicitante, r_mat.pk, p_fk_tperiodo_evaluacion);

        SELECT ipm.PROMEDIO, ipm.APROBADAS, ipm.REPROBADAS
          INTO v_m
          FROM academico_test.TINFORME_PERIODO_MATRICULA ipm
         WHERE ipm.FK_TMATRICULA          = r_mat.pk
           AND ipm.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
           AND ipm.ACTIVE = TRUE;

        -- Al historial SOLO si se escribio. Una asignatura por estudiante,
        -- de ahi el 1.
        IF v_res IN ('guardada', 'actualizada') THEN
            v_hist := v_hist || JSONB_BUILD_OBJECT(
                'matricula',   r_mat.pk,
                'promedio',    v_m.PROMEDIO,
                'asignaturas', 1);
        END IF;

        fk_tmatricula    := r_mat.pk;
        estudiante       := r_mat.nombre;
        resultado        := v_res;
        nota_anterior    := v_prev;
        nota_guardada    := CASE WHEN v_res IN ('guardada', 'actualizada', 'sin_cambio')
                                 THEN v_proy END;
        promedio_periodo := v_m.PROMEDIO;
        aprobadas        := COALESCE(v_m.APROBADAS, 0)::BIGINT;
        reprobadas       := COALESCE(v_m.REPROBADAS, 0)::BIGINT;
        RETURN NEXT;

        v_prev := NULL; v_existe := NULL;
    END LOOP;

    PERFORM academico_test.fn_informe_historial_registrar(
        p_pk_usuario_solicitante, p_fk_tgrupo, p_fk_tasignatura,
        p_fk_tperiodo_evaluacion, 'PLANILLA', v_hist);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_planilla_guardar(BIGINT, BIGINT, BIGINT, BIGINT, BIGINT[])
    IS 'Congela la definitiva de UNA asignatura desde la planilla de informes, para el grupo o solo las matriculas indicadas (NULL o vacio = todas), recalcula las metricas del periodo y registra el guardado en el historial con FK_TASIGNATURA puesta, que es lo que lo distingue del guardado del informe completo. Al historial solo entran los estudiantes a los que se les escribio (guardada o actualizada); sin_cambio y sin_proyeccion no cuentan, y si ninguno cambio no se crea cabecera. Es el hermano acotado de fn_informe_periodo_guardar y NO SE PISAN: TASIGNATURA_NOTA es por (matricula, periodo, asignatura), y ambas terminan llamando al mismo recalculo de metricas y al mismo registrador, de modo que el resultado no depende del orden y las dos son idempotentes. El recalculo corre SIEMPRE, incluso en sin_cambio, porque otra asignatura pudo haberse movido desde el ultimo y esa fila las agrega a todas. En sin_proyeccion lo ya guardado NO se borra: quitar un consolidado por una ausencia no es decision de un boton de guardar. Devuelve ademas el promedio y los conteos del periodo ya recalculados, para que la pantalla refresque sin volver a consultar. Gate: INFORMES/EDITAR sobre el grupo, mas el validador puro fn_planilla_grupo_asignatura_assert (V239). V538: escribe con fn_informe_nota_periodo_escribir_interno. Con una recuperacion de destino NOTA_FINAL la proyectada es la nueva BASE (CALIFICACION) y la DEFINITIVA se recombina con las reglas del modulo de recuperacion, en vez de pisar la recuperada; sin_cambio, NOTA_ANTERIOR y NOTA_GUARDADA se expresan sobre esa base.';
