-- ===========================================================================
-- V536 - Reconsolidar una nota con recuperacion de NOTA_FINAL la recombina.
--
--   El problema: fn_informe_periodo_guardar y fn_informe_planilla_guardar
--   hacen INSERT ... ON CONFLICT DO UPDATE SET CALIFICACION, DEFINITIVA con
--   la proyectada. Sobre una fila con recuperacion de NOTA_FINAL eso pisaba
--   la DEFINITIVA recuperada con la proyectada y dejaba RECUPERACION
--   colgando: la recuperacion se perdia sin que nadie la revirtiera.
--
--   La regla (opcion 2): la nota nueva es la nueva BASE. Se escribe en
--   CALIFICACION y la DEFINITIVA se vuelve a combinar con la recuperacion
--   usando las reglas del modulo de recuperacion -- REEMPLAZAR / COMPUTAR,
--   ponderacion, politica de sin calificar, piso, tope y redondeo --, sin
--   reimplementar ninguna: se llama a fn_actividad_recuperacion_consolidar_
--   interno, que en NOTA_FINAL toma la base justamente de CALIFICACION.
--
--   Por que el _interno y no fn_actividad_recuperacion_consolidar: el
--   publico evalua la aprobacion (Reglas 69/70) y, si no encuentra una
--   vigente, CREA una solicitud. Aca la recuperacion ya esta aplicada
--   (RECUPERACION no nula), o sea ya paso por esa aprobacion; lo unico que
--   cambia es la base. Llamar al publico generaria una solicitud nueva cada
--   vez que se pulsa guardar en el informe.
--
--   Y por eso tambien la actividad se ubica por su nota: debe ser la que
--   produjo RECUPERACION. Si el docente cambio despues la nota de la
--   recuperacion y la nueva espera aprobacion, esa no se usa -- seria
--   saltarse la aprobacion --; la DEFINITIVA conserva la resultante vigente
--   y se informa en el resultado.
--
--   Una recuperacion PENDIENTE no deja RECUPERACION en la fila, asi que se
--   guarda como cualquier otra; cuando la aprueben, el _interno tomara de
--   CALIFICACION la base que haya en ese momento.
--
--   Sin gate y sin etiqueta de auditoria: son INTERNAS y las llaman los dos
--   guardados despues de su propio gate (INFORMES/EDITAR).
--
-- Depende de: V496.19 (fn_actividad_recuperacion_consolidar_interno).
-- ===========================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_informe_recuperacion_nota_final_vigente(
    p_fk_tmatricula          BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tperiodo_evaluacion BIGINT
)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $function$
    SELECT ae.PK_TACTIVIDAD_ESTUDIANTE
      FROM academico_test.TASIGNATURA_NOTA sn
      JOIN academico_test.TACTIVIDAD a
        ON a.FK_TASIGNATURA  = sn.FK_TASIGNATURA
       AND a.ES_RECUPERACION = 'S'
       AND a.ACTIVE = TRUE
      JOIN academico_test.TACTIVIDAD_RECUPERACION r
        ON r.FK_TACTIVIDAD = a.PK_TACTIVIDAD
       AND r.ACTIVE = TRUE
      JOIN academico_test.TLISTA_VALOR lv
        ON lv.PK_LISTA_VALOR = r.FK_TLV_DESTINO_RECUPERACION
       AND lv.VALOR = 'NOTA_FINAL'
      JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
        ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
       AND ae.FK_TMATRICULA = sn.FK_TMATRICULA
       AND ae.ACTIVE = TRUE
      JOIN academico_test.TACTIVIDAD_NOTA n
        ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
       AND n.ACTIVE = TRUE
       -- La que produjo la RECUPERACION vigente; ver la cabecera.
       AND n.CALIFICACION = sn.RECUPERACION
     WHERE sn.FK_TMATRICULA          = p_fk_tmatricula
       AND sn.FK_TASIGNATURA         = p_fk_tasignatura
       AND sn.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
       AND sn.ACTIVE = TRUE
       AND sn.RECUPERACION IS NOT NULL
       AND academico_test.fn_actividad_periodo_evaluacion(a.PK_TACTIVIDAD, sn.FK_TMATRICULA)
           = sn.FK_TPERIODO_EVALUACION
     ORDER BY COALESCE(n.MODIFIED_AT, n.CREATED_AT) DESC, ae.PK_TACTIVIDAD_ESTUDIANTE DESC
     LIMIT 1;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_recuperacion_nota_final_vigente(BIGINT, BIGINT, BIGINT)
    IS 'INTERNO: PK_TACTIVIDAD_ESTUDIANTE de la recuperacion con destino NOTA_FINAL que produjo la RECUPERACION vigente de (matricula, asignatura, periodo) en TASIGNATURA_NOTA: actividad ES_RECUPERACION de la misma asignatura, cuyo periodo de evaluacion (fn_actividad_periodo_evaluacion) es ese, y cuya nota es IGUAL a TASIGNATURA_NOTA.RECUPERACION -- una nota cambiada despues y pendiente de aprobacion no cuenta. Si hay varias, la calificada mas recientemente. NULL si la fila no tiene recuperacion o no se ubica la actividad. Sin gate. La usa fn_informe_nota_periodo_escribir_interno (V536).';

CREATE OR REPLACE FUNCTION academico_test.fn_informe_nota_periodo_escribir_interno(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tmatricula          BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tperiodo_evaluacion BIGINT,
    p_nota                   NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
AS $function$
DECLARE
    v_pk_nota    BIGINT;
    v_recup      NUMERIC;
    v_pk_ae      BIGINT;
    v_res        JSONB;
    v_definitiva NUMERIC;
BEGIN
    SELECT sn.PK_TASIGNATURA_NOTA, sn.RECUPERACION
      INTO v_pk_nota, v_recup
      FROM academico_test.TASIGNATURA_NOTA sn
     WHERE sn.FK_TMATRICULA          = p_fk_tmatricula
       AND sn.FK_TASIGNATURA         = p_fk_tasignatura
       AND sn.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
       AND sn.ACTIVE = TRUE;

    -- Sin recuperacion: exactamente lo que hacian los dos guardados.
    IF v_recup IS NULL THEN
        INSERT INTO academico_test.TASIGNATURA_NOTA (
            FK_TMATRICULA, FK_TASIGNATURA, FK_TPERIODO_EVALUACION,
            CALIFICACION, DEFINITIVA, CREATED_BY, CREATED_AT, ACTIVE
        ) VALUES (
            p_fk_tmatricula, p_fk_tasignatura, p_fk_tperiodo_evaluacion,
            p_nota, p_nota,
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
        )
        ON CONFLICT (FK_TMATRICULA, FK_TPERIODO_EVALUACION, FK_TASIGNATURA)
            WHERE ACTIVE
        DO UPDATE SET CALIFICACION = EXCLUDED.CALIFICACION,
                      DEFINITIVA   = EXCLUDED.DEFINITIVA,
                      MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
                      MODIFIED_AT  = CURRENT_TIMESTAMP;

        RETURN JSONB_BUILD_OBJECT('definitiva', p_nota, 'con_recuperacion', FALSE);
    END IF;

    -- Con recuperacion: la nota nueva es la nueva base...
    UPDATE academico_test.TASIGNATURA_NOTA
       SET CALIFICACION = p_nota,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE PK_TASIGNATURA_NOTA = v_pk_nota;

    -- ...y la definitiva la recombina el modulo de recuperacion.
    v_pk_ae := academico_test.fn_informe_recuperacion_nota_final_vigente(
                   p_fk_tmatricula, p_fk_tasignatura, p_fk_tperiodo_evaluacion);
    IF v_pk_ae IS NULL THEN
        v_res := JSONB_BUILD_OBJECT('aplicada', FALSE, 'motivo', 'RECUPERACION_NO_UBICADA');
    ELSE
        v_res := academico_test.fn_actividad_recuperacion_consolidar_interno(
                     p_pk_usuario_solicitante, v_pk_ae, NULL);
    END IF;

    SELECT sn.DEFINITIVA INTO v_definitiva
      FROM academico_test.TASIGNATURA_NOTA sn
     WHERE sn.PK_TASIGNATURA_NOTA = v_pk_nota;

    RETURN JSONB_BUILD_OBJECT(
        'definitiva',       v_definitiva,
        'con_recuperacion', TRUE,
        'recombinada',      COALESCE((v_res->>'aplicada')::BOOLEAN, FALSE),
        'motivo',           v_res->'motivo');
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_informe_nota_periodo_escribir_interno(BIGINT, BIGINT, BIGINT, BIGINT, NUMERIC)
    IS 'INTERNO: escritura unica de la nota consolidada de (matricula, asignatura, periodo) que usan fn_informe_periodo_guardar y fn_informe_planilla_guardar. Sin recuperacion de NOTA_FINAL hace lo de siempre: CALIFICACION = DEFINITIVA = p_nota. Con recuperacion (TASIGNATURA_NOTA.RECUPERACION no nula) p_nota es la nueva BASE: va a CALIFICACION y la DEFINITIVA se recombina llamando a fn_actividad_recuperacion_consolidar_interno con la recuperacion que produjo RECUPERACION (fn_informe_recuperacion_nota_final_vigente), de modo que REEMPLAZAR/COMPUTAR, ponderacion, piso, tope y redondeo son los del modulo de recuperacion. Se usa el _interno y no el publico porque la recuperacion ya esta aplicada y aprobada: el publico crearia una solicitud de aprobacion por cada guardado. Si no se puede recombinar (actividad no ubicada, nota final no editable, etc.) la DEFINITIVA conserva la resultante vigente. Devuelve {definitiva, con_recuperacion, recombinada, motivo}. Sin gate ni etiqueta: la llaman los guardados despues de su gate.';
