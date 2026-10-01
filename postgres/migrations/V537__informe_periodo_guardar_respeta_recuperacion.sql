-- ===========================================================================
-- V537 - Consolidar el periodo no pisa una recuperacion de NOTA_FINAL.
--
--   fn_informe_periodo_guardar:
--     - escribe con fn_informe_nota_periodo_escribir_interno (V536): con
--       recuperacion, la proyectada pasa a CALIFICACION (la base) y la
--       DEFINITIVA se recombina; sin recuperacion, lo mismo de siempre.
--     - sin_cambio compara la proyectada contra la BASE cuando hay
--       recuperacion -- contra la definitiva nunca coincidiria y cada
--       guardado reescribiria la fila.
--     - el detalle de lo escrito agrega 'definitiva' y 'recombinada' cuando
--       hubo recuperacion; 'nota' y 'anterior' son la base.
--
-- Depende de: V490 (ultimo cuerpo), V535, V536.
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_informe_periodo_guardar(p_pk_usuario_solicitante bigint, p_fk_tgrupo bigint, p_fk_tperiodo_evaluacion bigint, p_fk_tmatriculas bigint[] DEFAULT NULL::bigint[])
 RETURNS TABLE(fk_tmatricula bigint, estudiante character varying, guardadas bigint, actualizadas bigint, sin_proyeccion bigint, sin_cambio bigint, promedio numeric, aprobadas bigint, reprobadas bigint, detalle jsonb)
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
DECLARE
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_fk_peraca  BIGINT;
    v_pe_peraca  BIGINT;
    r_mat        RECORD;
    r_asig       RECORD;
    v_prev       NUMERIC;
    v_existe     BOOLEAN;
    v_g          BIGINT;
    v_a          BIGINT;
    v_s          BIGINT;
    v_n          BIGINT;
    v_det        JSONB;
    v_m          RECORD;
    v_hist       JSONB := '[]'::JSONB;
    v_esc        JSONB;
    v_extra      JSONB;
BEGIN
    SELECT s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO,
           gd.FK_TPERIODO_ACADEMICO
      INTO v_fk_sede, v_fk_jornada, v_fk_ee, v_fk_peraca
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
        v_g := 0; v_a := 0; v_s := 0; v_n := 0; v_det := '[]'::JSONB;

        FOR r_asig IN
            SELECT d.fk_tasignatura, d.asignatura_nombre, d.nota_proyectada
              FROM academico_test.fn_informe_estudiante_asignaturas(
                       p_pk_usuario_solicitante, r_mat.pk,
                       ARRAY[p_fk_tperiodo_evaluacion]::BIGINT[]) d
        LOOP
            IF r_asig.nota_proyectada IS NULL THEN
                v_s := v_s + 1;
                v_det := v_det || JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.asignatura_nombre,
                    'resultado',  'sin_proyeccion');
                CONTINUE;
            END IF;

            -- V537 -- con recuperacion de NOTA_FINAL lo comparable con la
            -- proyectada es la ORIGINAL (CALIFICACION), no la resultante.
            SELECT CASE WHEN sn.RECUPERACION IS NOT NULL AND sn.DEFINITIVA IS NOT NULL
                        THEN sn.CALIFICACION ELSE sn.DEFINITIVA END, TRUE
              INTO v_prev, v_existe
              FROM academico_test.TASIGNATURA_NOTA sn
             WHERE sn.FK_TMATRICULA          = r_mat.pk
               AND sn.FK_TASIGNATURA         = r_asig.fk_tasignatura
               AND sn.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
               AND sn.ACTIVE = TRUE;

            IF COALESCE(v_existe, FALSE) AND v_prev = r_asig.nota_proyectada THEN
                v_n := v_n + 1;
                v_det := v_det || JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.asignatura_nombre,
                    'resultado',  'sin_cambio',
                    'nota',       r_asig.nota_proyectada);
                v_existe := NULL;
                CONTINUE;
            END IF;

            -- V537 -- escritura unica: con recuperacion de NOTA_FINAL la
            -- proyectada pasa a ser la base y la definitiva se recombina.
            v_esc := academico_test.fn_informe_nota_periodo_escribir_interno(
                         p_pk_usuario_solicitante, r_mat.pk, r_asig.fk_tasignatura,
                         p_fk_tperiodo_evaluacion, r_asig.nota_proyectada);
            v_extra := CASE WHEN (v_esc->>'con_recuperacion')::BOOLEAN
                            THEN JSONB_BUILD_OBJECT(
                                     'definitiva',  v_esc->'definitiva',
                                     'recombinada', v_esc->'recombinada')
                            ELSE '{}'::JSONB END;

            IF COALESCE(v_existe, FALSE) THEN
                v_a := v_a + 1;
                v_det := v_det || (JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.asignatura_nombre,
                    'resultado',  'actualizada',
                    'nota',       r_asig.nota_proyectada,
                    'anterior',   v_prev) || v_extra);
            ELSE
                v_g := v_g + 1;
                v_det := v_det || (JSONB_BUILD_OBJECT(
                    'asignatura', r_asig.asignatura_nombre,
                    'resultado',  'guardada',
                    'nota',       r_asig.nota_proyectada) || v_extra);
            END IF;

            v_existe := NULL;
        END LOOP;

        PERFORM academico_test.fn_informe_metricas_recalcular(
            p_pk_usuario_solicitante, r_mat.pk, p_fk_tperiodo_evaluacion);

        SELECT ipm.PROMEDIO, ipm.APROBADAS, ipm.REPROBADAS
          INTO v_m
          FROM academico_test.TINFORME_PERIODO_MATRICULA ipm
         WHERE ipm.FK_TMATRICULA          = r_mat.pk
           AND ipm.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
           AND ipm.ACTIVE = TRUE;

        -- Al historial SOLO si se escribio algo. Ver el punto (2).
        IF v_g + v_a > 0 THEN
            v_hist := v_hist || JSONB_BUILD_OBJECT(
                'matricula',   r_mat.pk,
                'promedio',    v_m.PROMEDIO,
                'asignaturas', v_g + v_a);
        END IF;

        fk_tmatricula  := r_mat.pk;
        estudiante     := r_mat.nombre;
        guardadas      := v_g;
        actualizadas   := v_a;
        sin_proyeccion := v_s;
        sin_cambio     := v_n;
        promedio       := v_m.PROMEDIO;
        aprobadas      := COALESCE(v_m.APROBADAS, 0)::BIGINT;
        reprobadas     := COALESCE(v_m.REPROBADAS, 0)::BIGINT;
        detalle        := v_det;
        RETURN NEXT;
    END LOOP;

    PERFORM academico_test.fn_informe_historial_registrar(
        p_pk_usuario_solicitante, p_fk_tgrupo, NULL,
        p_fk_tperiodo_evaluacion, 'INFORME', v_hist);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_periodo_guardar(BIGINT, BIGINT, BIGINT, BIGINT[])
    IS 'Consolida un periodo COMPLETO: congela la nota proyectada de cada asignatura en TASIGNATURA_NOTA para el grupo (o solo las matriculas indicadas; NULL o vacio = todas), deja las metricas al dia via fn_informe_metricas_recalcular y registra el guardado en el historial via fn_informe_historial_registrar con FK_TASIGNATURA NULL, que es lo que marca "informe completo". Al historial solo entran los estudiantes a los que se les ESCRIBIO alguna nota: los sin_cambio y sin_proyeccion no cuentan, y si ninguno cambio no se crea cabecera, para que volver a pulsar guardar no deje entradas vacias. Convive sin pisarse con fn_informe_planilla_guardar, que congela una sola asignatura: TASIGNATURA_NOTA es por (matricula, periodo, asignatura) y ambas terminan en el mismo recalculo y el mismo registrador, asi que son idempotentes y su efecto final no depende del orden. Lo ya guardado con el mismo valor se reporta sin_cambio y no se toca, para no borrar el MODIFIED_AT que dice cuando se consolido. DEFINITIVA se guarda en PORCENTAJE, no homologada, porque la escala depende de TCRITERIO_EVALUACION por (asignatura, grado) y puede cambiar. Preescolar no usa este endpoint: alli todo sale sin_proyeccion porque las observaciones se guardan con CALIFICABLE=N y no promedian. Gate: INFORMES/EDITAR. V537: escribe con fn_informe_nota_periodo_escribir_interno. Con una recuperacion de destino NOTA_FINAL la proyectada es la nueva BASE (CALIFICACION) y la DEFINITIVA se recombina con las reglas del modulo de recuperacion, en vez de pisar la recuperada; sin_cambio compara contra esa base. En el DETALLE, NOTA y ANTERIOR son la base y se agregan DEFINITIVA (la resultante) y RECOMBINADA.';
