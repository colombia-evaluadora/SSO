-- ===========================================================================
-- V461 - Soportes de la observacion de preescolar, uno a uno (TACTIVIDAD_SOPORTE).
-- Hoy solo se fijan por REEMPLAZO (BODY.EVIDENCIAS del PUT observar, V243) y
-- se leen dentro del detalle de nota (V241). Recurso propio:
--   GET  /planeador/actividades/estudiantes/:ID/soportes  (listar)
--   POST /planeador/actividades/estudiantes/:ID/soportes  (agregar UNO)
--   PUT  /planeador/actividades/estudiantes/soportes/:ID  (quitar UNO; sin DELETE)
-- Mismas reglas que el PUT observar: gate EDITAR de PLANEADOR, actividad
-- FORMATIVA y asistencia valida en FECHA. Depende de V243, V277 y V450.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) Listar
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_actividad_observacion_soportes_listar(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_observacion_soportes_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT
)
RETURNS TABLE (
    pk_tactividad_soporte BIGINT,
    fk_tarchivo           BIGINT,
    nombre                VARCHAR,
    urls3                 VARCHAR,
    peso                  BIGINT,
    etiqueta              VARCHAR,
    fecha                 DATE,
    created_at            TIMESTAMP
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_tactividad BIGINT;
BEGIN
    v_pk_tactividad := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);

    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, NULL, v_pk_tactividad);

    RETURN QUERY
    SELECT so.PK_TACTIVIDAD_SOPORTE,
           so.FK_TARCHIVO,
           ar.NOMBRE,
           ar.URLS3,
           ar.PESO,
           ar.ETIQUETA,
           so.FECHA,
           so.CREATED_AT
      FROM academico_test.TACTIVIDAD_SOPORTE so
      JOIN academico_test.TARCHIVO ar ON ar.PK_TARCHIVO = so.FK_TARCHIVO
     WHERE so.FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
       AND so.ACTIVE = TRUE
       AND so.FK_TARCHIVO IS NOT NULL
     ORDER BY so.PK_TACTIVIDAD_SOPORTE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_observacion_soportes_listar(BIGINT, BIGINT)
    IS 'Archivos de soporte ACTIVE adjuntos a la observacion de UN estudiante en una actividad (TACTIVIDAD_SOPORTE con FK_TARCHIVO, V243), con los datos del TARCHIVO (nombre, urls3, peso, etiqueta). Es la misma lista que la columna evidencias de fn_actividad_nota_leer (V241), expuesta como recurso propio para agregar/quitar uno a uno. Gate VER sobre PLANEADOR + alcance por la actividad; P0002 si la asignacion actividad-estudiante no existe o esta inactiva. Ordena por pk.';

-- ---------------------------------------------------------------------------
-- 2) Agregar UNO
-- ---------------------------------------------------------------------------
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
    v_pk_tactividad BIGINT;
    v_pk_soporte    BIGINT;
BEGIN
    v_pk_tactividad := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);

    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, NULL, v_pk_tactividad);

    IF NOT academico_test.fn_actividad_es_formativa(v_pk_tactividad) THEN
        RAISE EXCEPTION 'La actividad % tiene referente EVALUATIVO (o no tiene unidad): los soportes de observacion solo aplican a actividades FORMATIVAS', v_pk_tactividad
            USING ERRCODE = '22023';
    END IF;

    IF p_fk_tarchivo IS NULL THEN
        RAISE EXCEPTION 'p_fk_tarchivo es obligatorio' USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM academico_test.TARCHIVO
                    WHERE PK_TARCHIVO = p_fk_tarchivo AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El archivo % no existe o esta inactivo', p_fk_tarchivo
            USING ERRCODE = '23503';
    END IF;

    PERFORM academico_test.fn_actividad_nota_asistencia_assert_preescolar(p_pk_tactividad_estudiante, p_fecha);

    -- Reactivar antes que insertar: un_tactividad_soporte_archivo (V243) es
    -- parcial sobre ACTIVE, y la fila inactiva de un archivo ya quitado
    -- sigue existiendo.
    UPDATE academico_test.TACTIVIDAD_SOPORTE
       SET ACTIVE = TRUE, FECHA = p_fecha,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
       AND FK_TARCHIVO = p_fk_tarchivo
       AND ACTIVE = FALSE
    RETURNING PK_TACTIVIDAD_SOPORTE INTO v_pk_soporte;

    IF v_pk_soporte IS NOT NULL THEN
        RETURN v_pk_soporte;
    END IF;

    SELECT PK_TACTIVIDAD_SOPORTE INTO v_pk_soporte
      FROM academico_test.TACTIVIDAD_SOPORTE
     WHERE FK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante
       AND FK_TARCHIVO = p_fk_tarchivo
       AND ACTIVE = TRUE;

    IF FOUND THEN
        RETURN v_pk_soporte;              -- ya estaba adjunto: idempotente
    END IF;

    INSERT INTO academico_test.TACTIVIDAD_SOPORTE (
        FK_TACTIVIDAD_ESTUDIANTE, FK_TARCHIVO, FECHA, CREATED_BY, CREATED_AT, ACTIVE)
    VALUES (p_pk_tactividad_estudiante, p_fk_tarchivo, p_fecha,
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE)
    RETURNING PK_TACTIVIDAD_SOPORTE INTO v_pk_soporte;

    RETURN v_pk_soporte;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_observacion_soporte_agregar(BIGINT, BIGINT, BIGINT, DATE)
    IS 'Adjunta UN archivo (PK_TARCHIVO, ya subido por el file-service) a la observacion de UN estudiante en una actividad FORMATIVA, sin tocar los demas adjuntos -- a diferencia de fn_actividad_observacion_evidencias_set (V243), que reemplaza el set completo. Si el archivo ya estaba adjunto devuelve el mismo pk (idempotente); si estaba dado de baja lo reactiva. Mismas reglas que fn_actividad_observar_estudiante: gate EDITAR sobre PLANEADOR + alcance por la actividad, 22023 si la actividad no es FORMATIVA o si no hay asistencia valida en p_fecha (fn_actividad_nota_asistencia_assert_preescolar, V450), 23503 si el archivo no existe o esta inactivo, P0002 si la asignacion actividad-estudiante no existe. Retorna PK_TACTIVIDAD_SOPORTE.';

-- ---------------------------------------------------------------------------
-- 3) Quitar UNO (baja logica)
-- ---------------------------------------------------------------------------
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
    v_pk_ae         BIGINT;
    v_pk_tactividad BIGINT;
BEGIN
    SELECT FK_TACTIVIDAD_ESTUDIANTE INTO v_pk_ae
      FROM academico_test.TACTIVIDAD_SOPORTE
     WHERE PK_TACTIVIDAD_SOPORTE = p_pk_tactividad_soporte
       AND ACTIVE = TRUE
       AND FK_TARCHIVO IS NOT NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el soporte de observacion solicitado (o ya fue retirado)'
            USING ERRCODE = 'P0002';
    END IF;

    v_pk_tactividad := academico_test.fn_actividad_estudiante_actividad(v_pk_ae);

    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'EDITAR', NULL, NULL, NULL, v_pk_tactividad);

    IF NOT academico_test.fn_actividad_es_formativa(v_pk_tactividad) THEN
        RAISE EXCEPTION 'La actividad % tiene referente EVALUATIVO (o no tiene unidad): los soportes de observacion solo aplican a actividades FORMATIVAS', v_pk_tactividad
            USING ERRCODE = '22023';
    END IF;

    PERFORM academico_test.fn_actividad_nota_asistencia_assert_preescolar(v_pk_ae, p_fecha);

    UPDATE academico_test.TACTIVIDAD_SOPORTE
       SET ACTIVE = FALSE,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TACTIVIDAD_SOPORTE = p_pk_tactividad_soporte;

    RETURN p_pk_tactividad_soporte;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_observacion_soporte_quitar(BIGINT, BIGINT, DATE)
    IS 'Baja logica (ACTIVE=FALSE) de UN soporte de observacion por su PK_TACTIVIDAD_SOPORTE -- el pk que devuelven fn_actividad_observacion_soportes_listar y _soporte_agregar. El TARCHIVO no se toca: el binario sigue en el file-service. Mismas reglas que agregar: gate EDITAR sobre PLANEADOR + alcance por la actividad, 22023 si la actividad no es FORMATIVA o si no hay asistencia valida en p_fecha, P0002 si el soporte no existe o ya esta inactivo. Retorna el pk retirado.';

-- ---------------------------------------------------------------------------
-- 4) Endpoints (eval-col). Se borran por uuid y por (ruta, metodo) antes del
--    INSERT para que una edicion de este archivo si actualice la fila.
-- ---------------------------------------------------------------------------
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
    'V461 -- archivos de soporte adjuntos a la observacion de UN estudiante en una actividad de preescolar (fn_actividad_observacion_soportes_listar). :ID = PK_TACTIVIDAD_ESTUDIANTE (NO PK_TACTIVIDAD; sale de GET /planeador/actividades/:ID como estudiantes[].pkTactividadEstudiante). Una fila por adjunto ACTIVE: pk_tactividad_soporte (el que pide el PUT de quitar), fk_tarchivo, nombre, urls3, peso, etiqueta, fecha, created_at. Es la misma lista que la columna evidencias de GET /planeador/actividades/estudiantes/:ID/nota, como recurso propio. Gate VER sobre PLANEADOR + alcance por la actividad; 404 (P0002) si la asignacion actividad-estudiante no existe.'
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
    '{"PARAM.ID": "BIGINT", "BODY.FK_TARCHIVO": "BIGINT", "BODY.FECHA": "DATE"}'::jsonb,
    'V461 -- adjunta UN archivo a la observacion de UN estudiante en una actividad FORMATIVA (preescolar; fn_actividad_observacion_soporte_agregar) sin tocar los demas adjuntos -- a diferencia de BODY.EVIDENCIAS del PUT observar, que reemplaza el set completo. :ID = PK_TACTIVIDAD_ESTUDIANTE. BODY.FK_TARCHIVO obligatorio: el PK que devolvio el file-service al subir el binario (POST /api/files/**). BODY.FECHA opcional (default hoy) para el gate de asistencia, misma regla que el PUT observar. Devuelve pk_tactividad_soporte; si el archivo ya estaba adjunto devuelve el mismo pk (idempotente). Gate EDITAR sobre PLANEADOR + alcance por la actividad. 22023 si la actividad no es FORMATIVA o no hay asistencia valida ese dia; 23503 si el archivo no existe o esta inactivo; 404 (P0002) si la asignacion no existe.'
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
    'V461 -- quita UN archivo de soporte de la observacion (baja logica; fn_actividad_observacion_soporte_quitar). :ID = PK_TACTIVIDAD_SOPORTE, el pk de la relacion que devuelven el GET y el POST de /planeador/actividades/estudiantes/:ID/soportes (NO es el PK_TARCHIVO). Es PUT y no DELETE porque el catalogo no admite DELETE. BODY.FECHA opcional (default hoy) para el gate de asistencia. El binario no se borra del file-service. Gate EDITAR sobre PLANEADOR + alcance por la actividad. 22023 si la actividad no es FORMATIVA o no hay asistencia valida ese dia; 404 (P0002) si el soporte no existe o ya fue retirado.'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO NOTHING;

-- Escritura: los mismos roles del PUT observar. Lectura: ademas los roles con
-- lectura del Planeador (V284).
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
   AND q.path_template = '/planeador/actividades/estudiantes/soportes/:ID'
   AND q.http_method   = 'PUT'
ON CONFLICT DO NOTHING;

DO $$
DECLARE
    v_total INT;
BEGIN
    SELECT COUNT(*) INTO v_total
      FROM public.query q
      JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'eval-col'
       AND q.uuid IN ('eval-col-planeador-obs-soportes-listar-001',
                      'eval-col-planeador-obs-soportes-agregar-001',
                      'eval-col-planeador-obs-soportes-quitar-001');
    IF v_total <> 3 THEN
        RAISE EXCEPTION 'V461: se esperaban 3 filas de public.query para eval-col y hay %', v_total;
    END IF;
END $$;
