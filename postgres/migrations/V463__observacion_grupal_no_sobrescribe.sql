-- ===========================================================================
-- V463 -- la observacion grupal no pisa las observaciones ya registradas.
-- Que hace: fn_actividad_observar_grupal deja fuera del recorrido a los
--   estudiantes que YA tienen observacion no vacia; el resto se observa igual
--   y el retorno cuenta solo a los efectivamente observados.
-- Por que aqui: el UPDATE corria sobre todo el grupo, asi que una segunda
--   grupal -- o una grupal tras varias individuales -- borraba el texto
--   particular de cada estudiante sin aviso. Se omite en vez de abortar, la
--   misma semantica que ya usaba para el que no tiene asistencia ese dia.
--   Migracion nueva para no re-ejecutar V243 entera.
-- Depende de: V243 (definicion original), V227 (fn_actividad_nota_get_or_create).
-- ===========================================================================
SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_observar_grupal(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_observacion            TEXT,
    p_fecha                  DATE DEFAULT CURRENT_DATE,
    p_evidencias             BIGINT[] DEFAULT NULL
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_ae      BIGINT;
    v_pk_nota    BIGINT;
    v_observados INT := 0;
    v_omitidos   INT := 0;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, NULL, p_pk_tactividad
    );

    IF NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD WHERE PK_TACTIVIDAD = p_pk_tactividad AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se encontro la actividad solicitada' USING ERRCODE = 'P0002';
    END IF;

    IF NOT academico_test.fn_actividad_es_formativa(p_pk_tactividad) THEN
        RAISE EXCEPTION 'La actividad % tiene referente EVALUATIVO (o no tiene unidad): use fn_actividad_nota_calificar para calificar con nota numerica', p_pk_tactividad
            USING ERRCODE = '22023';
    END IF;

    IF p_observacion IS NULL OR TRIM(p_observacion) = '' THEN
        RAISE EXCEPTION 'p_observacion no puede estar vacia' USING ERRCODE = '22023';
    END IF;

    -- V463 -- cuantos quedan fuera por tener ya observacion, solo para el aviso.
    SELECT COUNT(*) INTO v_omitidos
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ae.FK_TACTIVIDAD = p_pk_tactividad AND ae.ACTIVE = TRUE
       AND EXISTS (SELECT 1
                     FROM academico_test.TACTIVIDAD_NOTA n
                    WHERE n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                      AND n.ACTIVE = TRUE
                      AND NULLIF(TRIM(n.OBSERVACION), '') IS NOT NULL);
    IF v_omitidos > 0 THEN
        RAISE WARNING 'fn_actividad_observar_grupal: se omiten % estudiante(s) de la actividad % que ya tienen observacion registrada; la grupal no sobrescribe',
            v_omitidos, p_pk_tactividad;
    END IF;

    FOR v_pk_ae IN
        SELECT ae.PK_TACTIVIDAD_ESTUDIANTE
          FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
         WHERE ae.FK_TACTIVIDAD = p_pk_tactividad AND ae.ACTIVE = TRUE
           -- V463 -- el que ya tiene observacion no entra: ni se le pisa el
           -- texto ni se le reemplazan las evidencias del paso de abajo.
           AND NOT EXISTS (SELECT 1
                             FROM academico_test.TACTIVIDAD_NOTA n
                            WHERE n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                              AND n.ACTIVE = TRUE
                              AND NULLIF(TRIM(n.OBSERVACION), '') IS NOT NULL)
    LOOP
        BEGIN
            PERFORM academico_test.fn_actividad_nota_asistencia_assert_preescolar(v_pk_ae, p_fecha);
        EXCEPTION WHEN SQLSTATE '22023' THEN
            -- Sin asistencia valida ese dia: se salta este estudiante y se
            -- sigue con el resto del grupo (ver cabecera).
            RAISE WARNING 'fn_actividad_observar_grupal: se omite TACTIVIDAD_ESTUDIANTE % (%): %',
                v_pk_ae, p_fecha, SQLERRM;
            CONTINUE;
        END;

        v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, v_pk_ae);

        UPDATE academico_test.TACTIVIDAD_NOTA
           SET OBSERVACION = p_observacion, CALIFICACION = NULL, CALIFICABLE = 'N',
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;

        -- Las mismas evidencias para cada observado: en la grupal el docente
        -- adjunta las fotos de la sesion, no unas por estudiante.
        PERFORM academico_test.fn_actividad_observacion_evidencias_set(
            p_pk_usuario_solicitante, v_pk_ae, p_evidencias, p_fecha);

        v_observados := v_observados + 1;
    END LOOP;

    RETURN v_observados;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_observar_grupal(BIGINT, BIGINT, TEXT, DATE, BIGINT[])
    IS 'Aplica la MISMA observacion (texto libre) a los TACTIVIDAD_ESTUDIANTE activos de una actividad FORMATIVA (preescolar/"Proyecto Pedagogico", fn_actividad_es_formativa=TRUE; 22023 si no lo es). NO SOBRESCRIBE (V463): el estudiante que ya tiene una OBSERVACION no vacia en su TACTIVIDAD_NOTA activa queda fuera del recorrido -- no se le pisa el texto ni se le reemplazan las evidencias --, se avisa con un RAISE WARNING con el total omitido y se continua con el resto; antes el UPDATE corria sobre todo el grupo, asi que una segunda grupal, o una grupal despues de varias individuales, borraba el texto particular de cada estudiante sin aviso. Por cada estudiante restante exige asistencia valida ese dia (fn_actividad_nota_asistencia_assert_preescolar); si no la tiene se OMITE con otro WARNING y se continua. Guarda OBSERVACION=p_observacion, CALIFICACION=NULL, CALIFICABLE=''N'' via fn_actividad_nota_get_or_create + UPDATE. Retorna la cantidad de estudiantes EFECTIVAMENTE observados, que puede ser menor al total del grupo por cualquiera de las dos omisiones (0 = todos ya tenian observacion o ninguno tenia asistencia valida). Para corregir una observacion ya registrada se usa la individual. Gate EDITAR sobre PLANEADOR. V243/V463.';
