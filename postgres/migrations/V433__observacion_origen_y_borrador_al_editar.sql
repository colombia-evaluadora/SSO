-- ===========================================================================
-- V433 - La etiqueta "Desactualizada" mentia en cuanto alguien editaba.
--
--   fn_estudiante_periodo_observacion_guardar   dos arreglos, misma firma
--   + backfill de las filas que ya quedaron con OBSERVACIONES_ORIGEN en NULL
--
--
-- EL SINTOMA
--   Se genera el resumen del periodo con el boton de IA, se corrige una
--   palabra, se guarda -- y la fila queda con la etiqueta "Desactualizada",
--   cuyo hover dice que el docente dejo observaciones NUEVAS despues de
--   guardar el texto. Es falso: no hay ninguna observacion posterior, el
--   texto se edito y nada mas.
--
--   De regalo, el estado quedaba en APROBADA cuando deberia decir MODIFICADA.
--
--
-- COMO SE DECIDE HOY LA ETIQUETA
--   El listado la calcula asi:
--
--     CASE WHEN ob.PK_... IS NULL THEN NULL
--          ELSE rs.obs_hoy > COALESCE(ob.OBSERVACIONES_ORIGEN, 0)
--     END
--
--   obs_hoy son las observaciones por actividad que el estudiante tiene AHORA
--   en ese periodo. OBSERVACIONES_ORIGEN es cuantas habia cuando se guardo el
--   texto. Si hoy hay mas que entonces, el resumen quedo viejo. La idea es
--   correcta; lo que falla es el dato.
--
--
-- POR QUE OBSERVACIONES_ORIGEN queda en NULL
--   La columna se llena SOLO con lo que el caller reenvie. El endpoint lo
--   acepta y el front lo manda -- pero unicamente cuando el texto viene del
--   boton de IA en ESA misma apertura del panel.
--
--   Al reabrir un resumen ya guardado, el panel arranca con el borrador en
--   blanco (el listado no devuelve OBSERVACION_IA, asi que no hay de donde
--   recuperarlo). Editar ahi y guardar manda el texto a secas, sin
--   OBSERVACION_IA y sin OBSERVACIONES_ORIGEN. Y entonces pasan las dos
--   cosas:
--
--     - OBSERVACIONES_ORIGEN se guarda NULL. El COALESCE del listado lo lee
--       como CERO, y cero es "cuando se guardo no habia ninguna", asi que
--       cualquier periodo con al menos una observacion queda marcado como
--       desactualizado, para siempre. NULL ahi significa "no se", y el
--       COALESCE lo convierte en "si".
--
--     - v_ia := COALESCE(p_observacion_ia, v_texto) -- o sea, se asume que
--       el texto ES el de la IA --, el estado se deduce comparando ambos y
--       da APROBADA. El texto editado se registra como aprobado sin cambios.
--
--   Verificado en test: las dos filas de TESTUDIANTE_PERIODO_OBSERVACION
--   tienen OBSERVACIONES_ORIGEN en NULL, estado APROBADA y
--   LENGTH(OBSERVACION) = LENGTH(OBSERVACION_IA), pese a haber sido editadas.
--   La que tiene observaciones de actividad sale con la etiqueta; la que no
--   tiene ninguna, no -- que es exactamente la huella de este defecto.
--
--
-- EL ARREGLO, DEL LADO DEL BACK
--   No hace falta pedirle nada al front: la funcion sabe contar.
--
--   (1) Si el caller no manda OBSERVACIONES_ORIGEN, se CUENTAN las
--       observaciones en el momento de guardar. Es la misma cuenta que hace
--       fn_estudiante_periodo_observacion_generar, y significa lo mismo:
--       cuantas habia cuando alguien dio el texto por bueno. Guardar sin
--       haber generado es justamente eso -- el docente acepto el texto con
--       las observaciones que hay hoy --, asi que contar ahora no es una
--       aproximacion: es el dato.
--
--       Cuando SI lo manda, se respeta, porque es mas preciso: es la cuenta
--       del instante en que se genero el borrador.
--
--   (2) Si el caller no manda OBSERVACION_IA y YA existe una fila, se
--       conserva la que estaba guardada en vez de dar por hecho que el texto
--       nuevo es el de la IA. Editar un resumen generado pasa a quedar como
--       MODIFICADA, que es lo que es.
--
--       Si no existe fila previa y tampoco viene OBSERVACION_IA, se mantiene
--       el comportamiento de siempre (v_ia := el texto, estado APROBADA).
--       Es el caso "lo escribi a mano desde cero", y cambiarlo a MODIFICADA
--       -- que se podria defender: no es lo que la IA escribio -- alteraria
--       el contrato documentado del endpoint. Queda anotado, no cambiado.
--
--   El front puede quedarse como esta. Si algun dia el listado devuelve
--   tambien OBSERVACION_IA, el panel va a poder mostrar en que se diferencia
--   el texto guardado del borrador; eso es una mejora, no un requisito.
--
--
-- EL BACKFILL, Y LO QUE CUESTA
--   Las filas que ya quedaron en NULL siguen mostrando la etiqueta hasta que
--   se vuelvan a guardar. Se les pone la cuenta de HOY.
--
--   Hay que decir lo que eso implica: si en alguna de esas filas el docente
--   de verdad dejo observaciones nuevas despues de guardar, el backfill le
--   apaga una etiqueta que era correcta. No hay forma de recuperar la cuenta
--   historica -- no se guardo --, y la alternativa es dejar la etiqueta
--   prendida en todas, donde tampoco distingue nada y ademas entrena a la
--   gente a ignorarla. Se elige el dato util.
--
-- Idempotente: CREATE OR REPLACE con la misma firma, y el backfill solo toca
-- las filas que siguen en NULL.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. Guardar: contar si no me dicen, y no pisar el borrador de la IA.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_estudiante_periodo_observacion_guardar(
    p_pk_usuario_solicitante bigint,
    p_fk_tmatricula          bigint,
    p_fk_tperiodo_evaluacion bigint,
    p_observacion            text,
    p_observacion_ia         text    DEFAULT NULL::text,
    p_observaciones_origen   numeric DEFAULT NULL::numeric
)
RETURNS bigint
LANGUAGE plpgsql
AS $function$
DECLARE
    v_fk_peraca  BIGINT;
    v_fk_sede    BIGINT;
    v_fk_jornada BIGINT;
    v_fk_ee      BIGINT;
    v_pe_peraca  BIGINT;
    v_texto      TEXT;
    v_ia         TEXT;
    v_ia_previa  TEXT;
    v_origen     NUMERIC;
    v_estado     VARCHAR;
    v_pk_estado  BIGINT;
    v_pk         BIGINT;
BEGIN
    v_texto := NULLIF(TRIM(COALESCE(p_observacion, '')), '');
    IF v_texto IS NULL THEN
        RAISE EXCEPTION 'La observacion no puede quedar vacia'
            USING ERRCODE = '22023',
                  HINT    = 'Para quitar un resumen ya guardado use fn_estudiante_periodo_observacion_eliminar';
    END IF;

    SELECT gd.FK_TPERIODO_ACADEMICO, s.PK_TSEDE, gr.FK_TLV_JORNADA, s.FK_TESTABLECIMIENTO
      INTO v_fk_peraca, v_fk_sede, v_fk_jornada, v_fk_ee
      FROM academico_test.TMATRICULA m
      JOIN academico_test.TGRUPO gr ON gr.PK_TGRUPO = m.FK_TGRUPO
      JOIN academico_test.TGRADO gd ON gd.PK_TGRADO = gr.FK_TGRADO
      JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = gd.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE m.PK_TMATRICULA = p_fk_tmatricula
       AND m.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro la matricula solicitada'
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
        RAISE EXCEPTION 'El periodo de evaluacion no pertenece al periodo academico de la matricula'
            USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'EDITAR',
        v_fk_ee, v_fk_sede, v_fk_jornada
    );

    -- *** V433 (2) *** El borrador guardado, si lo hay.
    SELECT ob.OBSERVACION_IA
      INTO v_ia_previa
      FROM academico_test.TESTUDIANTE_PERIODO_OBSERVACION ob
     WHERE ob.FK_TMATRICULA          = p_fk_tmatricula
       AND ob.FK_TPERIODO_EVALUACION = p_fk_tperiodo_evaluacion
       AND ob.ACTIVE = TRUE;

    -- Prioridad: lo que reenvia el caller, luego el borrador que ya estaba
    -- guardado, y recien al final el texto mismo. Ese ultimo caso es el de
    -- "lo escribi a mano desde cero", donde no hay borrador contra el cual
    -- comparar. Antes se saltaba el escalon del medio, y por eso editar un
    -- resumen ya guardado lo dejaba como APROBADA sin cambios.
    v_ia := COALESCE(
                NULLIF(TRIM(COALESCE(p_observacion_ia, '')), ''),
                NULLIF(TRIM(COALESCE(v_ia_previa,      '')), ''),
                v_texto);

    -- *** V433 (1) *** Si no me dicen cuantas habia, las cuento. NULL aca
    -- termina leyendose como CERO en el listado, y cero significa "no habia
    -- ninguna", que deja la fila marcada como desactualizada para siempre.
    v_origen := p_observaciones_origen;

    IF v_origen IS NULL THEN
        -- La MISMA cuenta que hace fn_estudiante_periodo_observacion_generar:
        -- las observaciones por actividad del estudiante en ese periodo, sin
        -- filtrar por asignatura -- en preescolar la evaluacion no es por
        -- dimension.
        SELECT COUNT(*)
          INTO v_origen
          FROM academico_test.TACTIVIDAD a
          JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
            ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
           AND ae.FK_TMATRICULA = p_fk_tmatricula
           AND ae.ACTIVE = TRUE
          JOIN academico_test.TACTIVIDAD_NOTA n
            ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
           AND n.ACTIVE = TRUE
         WHERE a.ACTIVE = TRUE
           AND NULLIF(TRIM(COALESCE(n.OBSERVACION, '')), '') IS NOT NULL
           AND academico_test.fn_actividad_en_periodo_eval(
                   a.PK_TACTIVIDAD, p_fk_tperiodo_evaluacion) = TRUE;
    END IF;

    -- El estado se DEDUCE del texto, no se pide por parametro: asi no puede
    -- contradecirlo.
    v_estado := CASE WHEN v_texto = TRIM(v_ia) THEN 'APROBADA' ELSE 'MODIFICADA' END;

    SELECT lv.PK_LISTA_VALOR INTO v_pk_estado
      FROM academico_test.TLISTA_VALOR lv
     WHERE lv.CATEGORIA = 'ESTADO_OBSERVACION_IA'
       AND lv.VALOR     = v_estado
       AND lv.ACTIVE    = TRUE;

    IF v_pk_estado IS NULL THEN
        RAISE EXCEPTION 'Falta el estado % en el catalogo ESTADO_OBSERVACION_IA', v_estado
            USING ERRCODE = 'P0002';
    END IF;

    -- El unico es TOTAL sobre (matricula, periodo): guardar REEMPLAZA. No se
    -- versiona, la unica verdad es lo que el docente acepto por ultima vez.
    INSERT INTO academico_test.TESTUDIANTE_PERIODO_OBSERVACION (
        FK_TMATRICULA, FK_TPERIODO_EVALUACION, FK_TLV_ESTADO_OBSERVACION,
        OBSERVACION, OBSERVACION_IA, OBSERVACIONES_ORIGEN,
        CREATED_BY, CREATED_AT, ACTIVE
    ) VALUES (
        p_fk_tmatricula, p_fk_tperiodo_evaluacion, v_pk_estado,
        v_texto, v_ia, v_origen,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    ON CONFLICT (FK_TMATRICULA, FK_TPERIODO_EVALUACION)
    DO UPDATE SET FK_TLV_ESTADO_OBSERVACION = EXCLUDED.FK_TLV_ESTADO_OBSERVACION,
                  OBSERVACION               = EXCLUDED.OBSERVACION,
                  OBSERVACION_IA            = EXCLUDED.OBSERVACION_IA,
                  OBSERVACIONES_ORIGEN      = EXCLUDED.OBSERVACIONES_ORIGEN,
                  ACTIVE                    = TRUE,
                  MODIFIED_BY               = p_pk_usuario_solicitante::VARCHAR,
                  MODIFIED_AT               = CURRENT_TIMESTAMP
    RETURNING PK_TESTUDIANTE_PERIODO_OBSERVACION INTO v_pk;

    RETURN v_pk;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_estudiante_periodo_observacion_guardar(BIGINT, BIGINT, BIGINT, TEXT, TEXT, NUMERIC)
    IS 'Guarda el resumen del periodo de un estudiante. Reemplaza: el indice unico es total sobre (matricula, periodo) y no se versiona. El ESTADO se deduce comparando el texto contra OBSERVACION_IA -- iguales APROBADA, distintos MODIFICADA --, nunca se pide por parametro. V433 arregla dos cosas que hacian mentir a la pantalla cuando alguien EDITABA un resumen ya guardado, porque en ese camino el front no reenvia ni el borrador ni la cuenta: (1) si no llega OBSERVACIONES_ORIGEN se CUENTAN las observaciones por actividad en el momento de guardar, con la misma consulta de fn_estudiante_periodo_observacion_generar, en vez de dejar la columna en NULL -- el listado la lee con COALESCE(...,0), y cero significa "no habia ninguna", de modo que toda fila con al menos una observacion quedaba marcada como Desactualizada para siempre; (2) si no llega OBSERVACION_IA se conserva el borrador YA GUARDADO en lugar de asumir que el texto nuevo es el de la IA, asi que editar un resumen generado queda como MODIFICADA y no como APROBADA. Sin fila previa y sin OBSERVACION_IA se mantiene el comportamiento anterior (el texto hace de borrador, estado APROBADA): es el caso de escribirlo a mano desde cero. V336, V413, V433.';


-- ---------------------------------------------------------------------------
-- 2. Backfill: las filas que ya quedaron en NULL muestran la etiqueta hasta
--    que alguien las vuelva a guardar. Se les pone la cuenta de hoy.
--
--    Lo que cuesta: si en alguna el docente si dejo observaciones nuevas
--    despues de guardar, se le apaga una etiqueta correcta. La cuenta
--    historica no se guardo y no hay de donde sacarla; la alternativa es
--    dejarla prendida en todas, donde no distingue nada. Ver la cabecera.
-- ---------------------------------------------------------------------------
UPDATE academico_test.TESTUDIANTE_PERIODO_OBSERVACION ob
   SET OBSERVACIONES_ORIGEN = (
           SELECT COUNT(*)
             FROM academico_test.TACTIVIDAD a
             JOIN academico_test.TACTIVIDAD_ESTUDIANTE ae
               ON ae.FK_TACTIVIDAD = a.PK_TACTIVIDAD
              AND ae.FK_TMATRICULA = ob.FK_TMATRICULA
              AND ae.ACTIVE = TRUE
             JOIN academico_test.TACTIVIDAD_NOTA n
               ON n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
              AND n.ACTIVE = TRUE
            WHERE a.ACTIVE = TRUE
              AND NULLIF(TRIM(COALESCE(n.OBSERVACION, '')), '') IS NOT NULL
              AND academico_test.fn_actividad_en_periodo_eval(
                      a.PK_TACTIVIDAD, ob.FK_TPERIODO_EVALUACION) = TRUE
       )
 WHERE ob.OBSERVACIONES_ORIGEN IS NULL
   AND ob.ACTIVE = TRUE;
