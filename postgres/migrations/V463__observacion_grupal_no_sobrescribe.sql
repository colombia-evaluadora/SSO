-- ===========================================================================
-- V463 -- observar (formativo): wrappers de la observación individual y
--   grupal. Gate EDITAR + Regla 54 (fn_actividad_assert_resultados), etiqueta
--   y núcleo _interno (V496.6) con texto ≤1000, Momento, hasta 3 archivos o
--   un enlace (Regla 61); la grupal no pisa resultados ya registrados y la
--   asistencia ya no bloquea (Regla 73). Quitar una evidencia por reemplazo
--   desmarca su ES_FAVORITO (fn_actividad_observacion_evidencias_set).
-- Depende de: V243, V461, V227, V496.5-V496.7 (validaciones, núcleos, gate).
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
    IS 'INTERNO: lo usan fn_actividad_observar_estudiante_interno y fn_actividad_observar_grupal_interno (V496.6). Fija los archivos adjuntos a la observacion de UN estudiante, con semantica de REEMPLAZO: el set queda exactamente el que se envia (los que ya no vienen se desactivan y pierden ES_FAVORITO, los que vuelven se reactivan sin favorito). NULL = no tocar nada y devuelve NULL; un array VACIO deja la observacion sin adjuntos. Los archivos van a TACTIVIDAD_SOPORTE (N:1 con TACTIVIDAD_ESTUDIANTE); el binario lo sube antes el file-service y aqui solo llega el PK_TARCHIVO. 23503 si algun archivo no existe. Retorna el total de adjuntos vivos tras la operacion. NO confundir con TASISTENCIA.FK_SOPORTE_ARCHIVO, el soporte de la excusa de inasistencia.';

-- Cambia la aridad: suma p_momento y p_enlace.
DROP FUNCTION IF EXISTS academico_test.fn_actividad_observar_estudiante(BIGINT, BIGINT, TEXT, DATE, BIGINT[]);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_observar_estudiante(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_observacion              TEXT,
    p_fecha                    DATE     DEFAULT CURRENT_DATE,
    p_evidencias               BIGINT[] DEFAULT NULL,
    p_momento                  VARCHAR  DEFAULT NULL,
    p_enlace                   VARCHAR  DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk BIGINT := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
BEGIN
    PERFORM academico_test.fn_actividad_assert_resultados(p_pk_usuario_solicitante, v_pk, 'EDITAR');
    PERFORM academico_test.fn_actividad_auditar(p_pk_usuario_solicitante, v_pk,
        format('Observación de %s en %s',
               academico_test.fn_actividad_estudiante_etiqueta(p_pk_tactividad_estudiante),
               academico_test.fn_actividad_etiqueta(v_pk)));
    PERFORM academico_test.fn_actividad_observar_estudiante_interno(
        p_pk_usuario_solicitante, p_pk_tactividad_estudiante, p_observacion, COALESCE(p_fecha, CURRENT_DATE),
        p_evidencias, p_momento, p_enlace);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_observar_estudiante(BIGINT, BIGINT, TEXT, DATE, BIGINT[], VARCHAR, VARCHAR)
    IS 'PUT /planeador/actividades/estudiantes/:ID/observar. Wrapper: gate EDITAR, Regla 54 y etiqueta; delega en fn_actividad_observar_estudiante_interno.';

-- Cambia la aridad: suma p_momento y p_enlace.
DROP FUNCTION IF EXISTS academico_test.fn_actividad_observar_grupal(BIGINT, BIGINT, TEXT, DATE, BIGINT[]);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_observar_grupal(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_observacion            TEXT,
    p_fecha                  DATE     DEFAULT CURRENT_DATE,
    p_evidencias             BIGINT[] DEFAULT NULL,
    p_momento                VARCHAR  DEFAULT NULL,
    p_enlace                 VARCHAR  DEFAULT NULL
)
RETURNS INT
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_assert_resultados(p_pk_usuario_solicitante, p_pk_tactividad, 'EDITAR');
    PERFORM academico_test.fn_actividad_auditar(p_pk_usuario_solicitante, p_pk_tactividad,
        format('Observación grupal en %s', academico_test.fn_actividad_etiqueta(p_pk_tactividad)));
    RETURN academico_test.fn_actividad_observar_grupal_interno(
        p_pk_usuario_solicitante, p_pk_tactividad, p_observacion, COALESCE(p_fecha, CURRENT_DATE),
        p_evidencias, p_momento, p_enlace);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_observar_grupal(BIGINT, BIGINT, TEXT, DATE, BIGINT[], VARCHAR, VARCHAR)
    IS 'POST /planeador/actividades/:ID/observar-grupal. Wrapper: gate EDITAR, Regla 54 y etiqueta; delega en fn_actividad_observar_grupal_interno.';

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
