-- ===========================================================================
-- V461 - Soportes de la observacion de preescolar, uno a uno (TACTIVIDAD_SOPORTE).
-- Recurso propio, ademas del reemplazo por BODY.EVIDENCIAS del PUT observar:
--   GET  /planeador/actividades/estudiantes/:ID/soportes  (listar)
--   POST /planeador/actividades/estudiantes/:ID/soportes  (agregar UNO; FILE)
--   PUT  /planeador/actividades/estudiantes/soportes/:ID  (quitar UNO; sin DELETE)
--   PUT  /planeador/actividades/estudiantes/soportes/:ID/favorito  (destacar UNO)
-- Wrappers: gate de resultados (alcance + Regla 54), etiqueta de auditoria y
-- nucleo _interno (V496.6: actividad formativa, referente activo, Regla 61).
-- Depende de V243, V277, V496.5-V496.7.
-- ===========================================================================

ALTER TABLE academico_test.TACTIVIDAD_SOPORTE
    ADD COLUMN IF NOT EXISTS ES_FAVORITO BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN academico_test.TACTIVIDAD_SOPORTE.ES_FAVORITO
    IS 'Evidencia destacada de la observacion: el boletin de preescolar la pone primera. A lo sumo una ACTIVE por TACTIVIDAD_ESTUDIANTE (un_tactividad_soporte_favorito); la baja logica la desmarca.';

CREATE UNIQUE INDEX IF NOT EXISTS un_tactividad_soporte_favorito
    ON academico_test.TACTIVIDAD_SOPORTE (fk_tactividad_estudiante)
 WHERE active = true AND es_favorito = true;

DROP FUNCTION IF EXISTS academico_test.fn_actividad_observacion_soportes_listar(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_observacion_soportes_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT
)
RETURNS TABLE (pk_tactividad_soporte BIGINT, fk_tarchivo BIGINT, nombre VARCHAR, urls3 VARCHAR, peso BIGINT,
               etiqueta VARCHAR, fecha DATE, created_at TIMESTAMP, es_favorito BOOLEAN)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_assert_resultados(p_pk_usuario_solicitante,
        academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante), 'VER');
    RETURN QUERY SELECT * FROM academico_test.fn_actividad_observacion_soportes_listar_interno(p_pk_tactividad_estudiante);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_observacion_soportes_listar(BIGINT, BIGINT)
    IS 'GET /planeador/actividades/estudiantes/:ID/soportes. Wrapper: gate VER y Regla 54; delega en fn_actividad_observacion_soportes_listar_interno.';

DROP FUNCTION IF EXISTS academico_test.fn_actividad_observacion_soporte_agregar(BIGINT, BIGINT, BIGINT, DATE);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_observacion_soporte_agregar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_fk_tarchivo              BIGINT,
    p_fecha                    DATE DEFAULT CURRENT_DATE
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk BIGINT := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
BEGIN
    PERFORM academico_test.fn_actividad_assert_resultados(p_pk_usuario_solicitante, v_pk, 'EDITAR');
    PERFORM academico_test.fn_actividad_auditar(p_pk_usuario_solicitante, v_pk,
        format('Evidencia agregada a la observación en %s', academico_test.fn_actividad_etiqueta(v_pk)));
    RETURN academico_test.fn_actividad_observacion_soporte_agregar_interno(
        p_pk_usuario_solicitante, p_pk_tactividad_estudiante, p_fk_tarchivo, COALESCE(p_fecha, CURRENT_DATE));
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_observacion_soporte_agregar(BIGINT, BIGINT, BIGINT, DATE)
    IS 'POST /planeador/actividades/estudiantes/:ID/soportes. Wrapper: gate EDITAR, Regla 54 y etiqueta; delega en fn_actividad_observacion_soporte_agregar_interno (Regla 61).';

DROP FUNCTION IF EXISTS academico_test.fn_actividad_observacion_soporte_quitar(BIGINT, BIGINT, DATE);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_observacion_soporte_quitar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad_soporte  BIGINT,
    p_fecha                  DATE DEFAULT CURRENT_DATE
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk BIGINT := academico_test.fn_actividad_estudiante_actividad(
                       academico_test.fn_actividad_observacion_soporte_resolver(p_pk_tactividad_soporte));
BEGIN
    PERFORM academico_test.fn_actividad_assert_resultados(p_pk_usuario_solicitante, v_pk, 'EDITAR');
    PERFORM academico_test.fn_actividad_auditar(p_pk_usuario_solicitante, v_pk,
        format('Evidencia retirada de la observación en %s', academico_test.fn_actividad_etiqueta(v_pk)));
    RETURN academico_test.fn_actividad_observacion_soporte_quitar_interno(p_pk_usuario_solicitante, p_pk_tactividad_soporte);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_observacion_soporte_quitar(BIGINT, BIGINT, DATE)
    IS 'PUT /planeador/actividades/estudiantes/soportes/:ID. Wrapper: P0002, gate EDITAR, Regla 54 y etiqueta; delega en fn_actividad_observacion_soporte_quitar_interno. p_fecha se conserva por contrato y ya no se usa.';

DROP FUNCTION IF EXISTS academico_test.fn_actividad_observacion_soporte_favorito(BIGINT, BIGINT, BOOLEAN);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_observacion_soporte_favorito(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad_soporte  BIGINT,
    p_es_favorito            BOOLEAN DEFAULT TRUE
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk BIGINT := academico_test.fn_actividad_estudiante_actividad(
                       academico_test.fn_actividad_observacion_soporte_resolver(p_pk_tactividad_soporte));
BEGIN
    PERFORM academico_test.fn_actividad_assert_resultados(p_pk_usuario_solicitante, v_pk, 'EDITAR');
    PERFORM academico_test.fn_actividad_auditar(p_pk_usuario_solicitante, v_pk,
        format(CASE WHEN COALESCE(p_es_favorito, TRUE) THEN 'Evidencia destacada en la observación de %s'
                    ELSE 'Evidencia sin destacar en la observación de %s' END,
               academico_test.fn_actividad_etiqueta(v_pk)));
    RETURN academico_test.fn_actividad_observacion_soporte_favorito_interno(
        p_pk_usuario_solicitante, p_pk_tactividad_soporte, p_es_favorito);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_observacion_soporte_favorito(BIGINT, BIGINT, BOOLEAN)
    IS 'PUT /planeador/actividades/estudiantes/soportes/:ID/favorito. Wrapper: P0002, gate EDITAR, Regla 54 y etiqueta; delega en fn_actividad_observacion_soporte_favorito_interno.';

DELETE FROM public.query q
 USING public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND (q.uuid = 'eval-col-planeador-obs-soportes-listar-001'
        OR (q.path_template = '/planeador/actividades/estudiantes/:ID/soportes' AND q.http_method = 'GET'));

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    'eval-col-planeador-obs-soportes-listar-001',
    'SELECT * FROM academico_test.fn_actividad_observacion_soportes_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/estudiantes/:ID/soportes', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V461 -- archivos de soporte adjuntos a la observacion de UN estudiante en una actividad de preescolar (fn_actividad_observacion_soportes_listar). :ID = PK_TACTIVIDAD_ESTUDIANTE (NO PK_TACTIVIDAD; sale de GET /planeador/actividades/:ID como estudiantes[].pkTactividadEstudiante). Una fila por adjunto ACTIVE: pk_tactividad_soporte (el que pide el PUT de quitar), fk_tarchivo, nombre, urls3, peso, etiqueta, fecha, created_at. Es la misma lista que la columna evidencias de GET /planeador/actividades/estudiantes/:ID/nota, como recurso propio. Gate VER sobre PLANEADOR + alcance por la actividad + Regla 54; 404 (P0002) si la asignacion actividad-estudiante no existe.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

DELETE FROM public.query q
 USING public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND (q.uuid = 'eval-col-planeador-obs-soportes-agregar-001'
        OR (q.path_template = '/planeador/actividades/estudiantes/:ID/soportes' AND q.http_method = 'POST'));

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    'eval-col-planeador-obs-soportes-agregar-001',
    'SELECT academico_test.fn_actividad_observacion_soporte_agregar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.FK_TARCHIVO AS BIGINT),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE)
) AS pk_tactividad_soporte;',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/estudiantes/:ID/soportes', 'SELECT', 'POST',
    '{"PARAM.ID": "BIGINT", "BODY.FK_TARCHIVO": "FILE:actividad", "BODY.FECHA": "DATE"}'::jsonb,
    'V461 -- adjunta UN archivo a la observacion de UN estudiante en una actividad FORMATIVA (preescolar; fn_actividad_observacion_soporte_agregar) sin tocar los demas adjuntos -- a diferencia de BODY.EVIDENCIAS del PUT observar, que reemplaza el set completo. :ID = PK_TACTIVIDAD_ESTUDIANTE. BODY.FK_TARCHIVO esta declarado FILE:actividad, asi que hay DOS formas de llamarlo. (1) Un solo paso, la normal: multipart a POST /api/files/eval-col/planeador/actividades/estudiantes/:ID/soportes con el binario en el campo FK_TARCHIVO y FECHA como campo de texto; file-service sube a S3, reserva la fila de TARCHIVO, la reemplaza por su pk y reenvia aca como JSON. (2) JSON directo a este path con un PK_TARCHIVO que ya exista. La carpeta S3 es actividad/<pk>.<ext>, la misma de los materiales de actividad. BODY.FECHA opcional (default hoy): fecha del soporte; la asistencia ya no bloquea. Devuelve pk_tactividad_soporte; si el archivo ya estaba adjunto devuelve el mismo pk (idempotente). Gate EDITAR sobre PLANEADOR + alcance por la actividad + Regla 54 (un docente solo en actividades que creo), y para la via multipart ademas el binding role_endpoint POST /files/**. 22023 si la actividad no es FORMATIVA, su referente esta inactivo o se excede la Regla 61 (hasta 3 archivos pdf/doc/docx/jpg/png de 10 MB, o un enlace); 23503 si el archivo no existe; 404 (P0002) si la asignacion no existe.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

DELETE FROM public.query q
 USING public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND (q.uuid = 'eval-col-planeador-obs-soportes-quitar-001'
        OR (q.path_template = '/planeador/actividades/estudiantes/soportes/:ID' AND q.http_method = 'PUT'));

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    'eval-col-planeador-obs-soportes-quitar-001',
    'SELECT academico_test.fn_actividad_observacion_soporte_quitar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    COALESCE(CAST(:BODY.FECHA AS DATE), CURRENT_DATE)
) AS pk_tactividad_soporte;',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/estudiantes/soportes/:ID', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.FECHA": "DATE"}'::jsonb,
    'V461 -- quita UN archivo de soporte de la observacion (baja logica; fn_actividad_observacion_soporte_quitar). :ID = PK_TACTIVIDAD_SOPORTE, el pk de la relacion que devuelven el GET y el POST de /planeador/actividades/estudiantes/:ID/soportes (NO es el PK_TARCHIVO). Es PUT y no DELETE porque el catalogo no admite DELETE. BODY.FECHA se conserva por contrato y ya no se usa. El binario no se borra del file-service. Gate EDITAR sobre PLANEADOR + alcance por la actividad + Regla 54. 22023 si la actividad no es FORMATIVA o su referente esta inactivo; 404 (P0002) si el soporte no existe o ya fue retirado.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

DELETE FROM public.query q
 USING public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND (q.uuid = 'eval-col-planeador-obs-soportes-favorito-001'
        OR (q.path_template = '/planeador/actividades/estudiantes/soportes/:ID/favorito' AND q.http_method = 'PUT'));

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template, execution_mode, http_method, param_types, detail)
SELECT
    'eval-col-planeador-obs-soportes-favorito-001',
    'SELECT academico_test.fn_actividad_observacion_soporte_favorito(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    COALESCE(CAST(:BODY.ES_FAVORITO AS BOOLEAN), TRUE)
) AS pk_tactividad_soporte;',
    'postgres', false, false,
    m.id_microservice, '/planeador/actividades/estudiantes/soportes/:ID/favorito', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT", "BODY.ES_FAVORITO": "BOOLEAN"}'::jsonb,
    'V461 -- marca o desmarca la evidencia favorita de la observacion (fn_actividad_observacion_soporte_favorito). :ID = PK_TACTIVIDAD_SOPORTE (el pk_tactividad_soporte del GET/POST de /planeador/actividades/estudiantes/:ID/soportes, NO el PK_TARCHIVO). BODY.ES_FAVORITO opcional, default true; marcar desmarca la favorita anterior, asi que queda a lo sumo una por estudiante-actividad. Se lee como es_favorito en el GET de soportes y el boletin de preescolar la pone primera. Quitar el soporte tambien la desmarca. Gate EDITAR sobre PLANEADOR + alcance por la actividad + Regla 54. 22023 si la actividad no es FORMATIVA o su referente esta inactivo; 404 (P0002) si el soporte no existe o ya fue retirado.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DOCENTE', 'CEVAL-RECTOR', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/planeador/actividades/estudiantes/:ID/soportes'
   AND q.http_method   = 'GET'
ON CONFLICT DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DOCENTE')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template = '/planeador/actividades/estudiantes/:ID/soportes'
   AND q.http_method   = 'POST'
ON CONFLICT DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id
  JOIN public.role r ON r.name IN ('CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-DOCENTE')
 WHERE m.serviceid     = 'eval-col'
   AND q.path_template IN ('/planeador/actividades/estudiantes/soportes/:ID',
                           '/planeador/actividades/estudiantes/soportes/:ID/favorito')
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;
