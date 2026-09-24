-- ===========================================================================
-- V463 -- observar (formativo): la grupal no pisa y el texto es opcional.
-- Que hace: la grupal omite a quien ya tiene observacion (texto o evidencias);
--   individual y grupal aceptan observacion SIN texto si trae evidencias, y
--   editarla despues puede dejar el texto vacio. Quitar una evidencia por
--   reemplazo desmarca su ES_FAVORITO.
-- Por que aqui: redefine funciones de V243 sin re-ejecutar V243 entera, y va
--   despues de V461, que crea TACTIVIDAD_SOPORTE.ES_FAVORITO.
-- Depende de: V243, V461, V227 (fn_actividad_nota_get_or_create).
-- ===========================================================================
SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_observacion_evidencias_set(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_evidencias               BIGINT[],
    p_fecha                    DATE DEFAULT CURRENT_DATE
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_set    BIGINT[];
    v_total  INT;
BEGIN
    IF p_evidencias IS NULL THEN
        RETURN NULL;                  -- NULL = no tocar los adjuntos
    END IF;

    -- Sin los NULL: con uno dentro, "<> ALL" no desactivaria nada.
    v_set := ARRAY(SELECT x FROM unnest(p_evidencias) x WHERE x IS NOT NULL);

    IF EXISTS (SELECT 1 FROM unnest(v_set) a
                WHERE NOT EXISTS (SELECT 1 FROM academico_test.TARCHIVO
                                   WHERE PK_TARCHIVO = a)) THEN
        RAISE EXCEPTION 'Uno o mas archivos de la observacion no existen'
            USING ERRCODE = '23503';
    END IF;

    UPDATE academico_test.TACTIVIDAD_SOPORTE
       SET ACTIVE = FALSE, ES_FAVORITO = FALSE,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
       AND ACTIVE = TRUE
       AND FK_TARCHIVO IS NOT NULL
       AND FK_TARCHIVO <> ALL(v_set);

    UPDATE academico_test.TACTIVIDAD_SOPORTE so
       SET ACTIVE = TRUE, FECHA = p_fecha,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
      FROM unnest(v_set) a
     WHERE so.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
       AND so.FK_TARCHIVO = a
       AND so.ACTIVE = FALSE;

    INSERT INTO academico_test.TACTIVIDAD_SOPORTE (
        FK_TACTIVIDAD_ESTUDIANTE, FK_TARCHIVO, FECHA, CREATED_BY, CREATED_AT, ACTIVE)
    SELECT DISTINCT p_pk_tactividad_estudiante, a, p_fecha,
           p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
      FROM unnest(v_set) a
     WHERE NOT EXISTS (SELECT 1 FROM academico_test.TACTIVIDAD_SOPORTE so
                        WHERE so.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
                          AND so.FK_TARCHIVO = a);

    SELECT COUNT(*) INTO v_total
      FROM academico_test.TACTIVIDAD_SOPORTE
     WHERE FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
       AND ACTIVE = TRUE AND FK_TARCHIVO IS NOT NULL;

    RETURN v_total;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_observacion_evidencias_set(BIGINT, BIGINT, BIGINT[], DATE)
    IS 'INTERNO: lo usan fn_actividad_observar_estudiante y fn_actividad_observar_grupal. Fija los archivos adjuntos a la observacion de UN estudiante, con semantica de REEMPLAZO: el set queda exactamente el que se envia (los que ya no vienen se desactivan y pierden ES_FAVORITO, los que vuelven se reactivan sin favorito). NULL = no tocar nada y devuelve NULL; un array VACIO deja la observacion sin adjuntos. Los archivos van a TACTIVIDAD_SOPORTE (N:1 con TACTIVIDAD_ESTUDIANTE); el binario lo sube antes el file-service y aqui solo llega el PK_TARCHIVO. 23503 si algun archivo no existe. Retorna el total de adjuntos vivos tras la operacion. NO confundir con TASISTENCIA.FK_SOPORTE_ARCHIVO, el soporte de la excusa de inasistencia.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_observar_estudiante(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_observacion              TEXT,
    p_fecha                    DATE DEFAULT CURRENT_DATE,
    p_evidencias               BIGINT[] DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk_tactividad BIGINT;
    v_pk_nota       BIGINT;
    v_evidencias    INT;
BEGIN
    v_pk_tactividad := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);

    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, NULL, v_pk_tactividad);

    IF NOT academico_test.fn_actividad_es_formativa(v_pk_tactividad) THEN
        RAISE EXCEPTION 'La actividad % tiene referente EVALUATIVO (o no tiene unidad): use fn_actividad_nota_calificar para calificar con nota numerica', v_pk_tactividad
            USING ERRCODE = '22023';
    END IF;

    -- A diferencia de la grupal, aqui SI se propaga el error del gate de
    -- asistencia: es una accion puntual y quien la invoca debe saber por que.
    PERFORM academico_test.fn_actividad_nota_asistencia_assert_preescolar(p_pk_tactividad_estudiante, p_fecha);

    v_pk_nota := academico_test.fn_actividad_nota_get_or_create(p_pk_usuario_solicitante, p_pk_tactividad_estudiante);

    -- Texto vacio = observacion sin texto (se guarda NULL), no un error.
    UPDATE academico_test.TACTIVIDAD_NOTA
       SET OBSERVACION = NULLIF(TRIM(p_observacion), ''), CALIFICACION = NULL, CALIFICABLE = 'N',
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_NOTA = v_pk_nota;

    v_evidencias := academico_test.fn_actividad_observacion_evidencias_set(
        p_pk_usuario_solicitante, p_pk_tactividad_estudiante, p_evidencias, p_fecha);

    -- Tras aplicar el set: con EVIDENCIAS omitidas cuentan los adjuntos que ya
    -- tenia. Una observacion sin texto ni evidencias no es nada; el RAISE
    -- deshace el UPDATE.
    IF NULLIF(TRIM(p_observacion), '') IS NULL
       AND COALESCE(v_evidencias,
                    (SELECT COUNT(*) FROM academico_test.TACTIVIDAD_SOPORTE
                      WHERE FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
                        AND ACTIVE = TRUE AND FK_TARCHIVO IS NOT NULL)) = 0 THEN
        RAISE EXCEPTION 'La observacion necesita texto o al menos una evidencia'
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_observar_estudiante(BIGINT, BIGINT, TEXT, DATE, BIGINT[])
    IS 'PUT /planeador/actividades/estudiantes/:ID/observar. Observacion particular de UN estudiante en una actividad FORMATIVA (preescolar; 22023 si no lo es). Sobreescribe lo que hubiera para ESE estudiante (get-or-create de TACTIVIDAD_NOTA + UPDATE), incluida una observacion de la grupal. El TEXTO ES OPCIONAL: vacio o NULL guarda OBSERVACION=NULL, asi que se puede registrar una observacion solo con evidencias y editarla despues agregandole texto o dejandolo vacio; lo que no se admite (22023) es que quede sin texto Y sin evidencias vivas -- con p_evidencias NULL cuentan los adjuntos que ya tenia. p_evidencias sigue la semantica de REEMPLAZO de fn_actividad_observacion_evidencias_set. Exige asistencia valida ese dia y PROPAGA el error. Guarda CALIFICACION=NULL, CALIFICABLE=''N''. Gate EDITAR sobre PLANEADOR + alcance.';

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

    -- Sin texto vale si trae evidencias: la observacion puede ser solo fotos.
    IF NULLIF(TRIM(p_observacion), '') IS NULL
       AND NOT EXISTS (SELECT 1 FROM unnest(p_evidencias) x WHERE x IS NOT NULL) THEN
        RAISE EXCEPTION 'La observacion necesita texto o al menos una evidencia'
            USING ERRCODE = '22023';
    END IF;

    -- Cuantos quedan fuera por tener ya observacion, solo para el aviso.
    -- Observado = texto no vacio O evidencias vivas: una observacion de solo
    -- fotos tambien es de ese estudiante y la grupal no se la reemplaza.
    SELECT COUNT(*) INTO v_omitidos
      FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
     WHERE ae.FK_TACTIVIDAD = p_pk_tactividad AND ae.ACTIVE = TRUE
       AND (EXISTS (SELECT 1
                      FROM academico_test.TACTIVIDAD_NOTA n
                     WHERE n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                       AND n.ACTIVE = TRUE
                       AND NULLIF(TRIM(n.OBSERVACION), '') IS NOT NULL)
            OR EXISTS (SELECT 1
                         FROM academico_test.TACTIVIDAD_SOPORTE so
                        WHERE so.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                          AND so.ACTIVE = TRUE AND so.FK_TARCHIVO IS NOT NULL));
    IF v_omitidos > 0 THEN
        RAISE WARNING 'fn_actividad_observar_grupal: se omiten % estudiante(s) de la actividad % que ya tienen observacion registrada; la grupal no sobrescribe',
            v_omitidos, p_pk_tactividad;
    END IF;

    FOR v_pk_ae IN
        SELECT ae.PK_TACTIVIDAD_ESTUDIANTE
          FROM academico_test.TACTIVIDAD_ESTUDIANTE ae
         WHERE ae.FK_TACTIVIDAD = p_pk_tactividad AND ae.ACTIVE = TRUE
           -- El que ya tiene observacion no entra: ni se le pisa el texto
           -- ni se le reemplazan las evidencias del paso de abajo.
           AND NOT EXISTS (SELECT 1
                             FROM academico_test.TACTIVIDAD_NOTA n
                            WHERE n.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                              AND n.ACTIVE = TRUE
                              AND NULLIF(TRIM(n.OBSERVACION), '') IS NOT NULL)
           AND NOT EXISTS (SELECT 1
                             FROM academico_test.TACTIVIDAD_SOPORTE so
                            WHERE so.FK_TACTIVIDAD_ESTUDIANTE = ae.PK_TACTIVIDAD_ESTUDIANTE
                              AND so.ACTIVE = TRUE AND so.FK_TARCHIVO IS NOT NULL)
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
           SET OBSERVACION = NULLIF(TRIM(p_observacion), ''), CALIFICACION = NULL, CALIFICABLE = 'N',
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
    IS 'Aplica la MISMA observacion (texto libre y/o evidencias) a los TACTIVIDAD_ESTUDIANTE activos de una actividad FORMATIVA (preescolar/"Proyecto Pedagogico", fn_actividad_es_formativa=TRUE; 22023 si no lo es). El texto es opcional si p_evidencias trae al menos un archivo (se guarda OBSERVACION=NULL); sin texto ni evidencias, 22023. Cuenta como "ya observado" tener texto no vacio O evidencias vivas. NO SOBRESCRIBE (V463): el estudiante que ya tiene una OBSERVACION no vacia en su TACTIVIDAD_NOTA activa queda fuera del recorrido -- no se le pisa el texto ni se le reemplazan las evidencias --, se avisa con un RAISE WARNING con el total omitido y se continua con el resto; antes el UPDATE corria sobre todo el grupo, asi que una segunda grupal, o una grupal despues de varias individuales, borraba el texto particular de cada estudiante sin aviso. Por cada estudiante restante exige asistencia valida ese dia (fn_actividad_nota_asistencia_assert_preescolar); si no la tiene se OMITE con otro WARNING y se continua. Guarda OBSERVACION=p_observacion, CALIFICACION=NULL, CALIFICABLE=''N'' via fn_actividad_nota_get_or_create + UPDATE. Retorna la cantidad de estudiantes EFECTIVAMENTE observados, que puede ser menor al total del grupo por cualquiera de las dos omisiones (0 = todos ya tenian observacion o ninguno tenia asistencia valida). Para corregir una observacion ya registrada se usa la individual. Gate EDITAR sobre PLANEADOR. V243/V463.';

-- El detail de V246 decia "BODY.OBSERVACION obligatoria"; ON CONFLICT DO
-- NOTHING no lo actualiza editando V246. REPLACE es idempotente.
UPDATE public.query q
   SET detail = REPLACE(REPLACE(q.detail,
           'BODY.OBSERVACION obligatoria (no vacia)',
           'BODY.OBSERVACION opcional si BODY.EVIDENCIAS trae al menos un archivo (sin texto ni evidencias: 22023)'),
           'BODY.OBSERVACION obligatoria;',
           'BODY.OBSERVACION opcional: vacia guarda la observacion sin texto, pero debe quedar con texto o con evidencias vivas (22023 si no);')
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND ((q.path_template = '/planeador/actividades/:ID/observar-grupal' AND q.http_method = 'POST')
     OR (q.path_template = '/planeador/actividades/estudiantes/:ID/observar' AND q.http_method = 'PUT'));
