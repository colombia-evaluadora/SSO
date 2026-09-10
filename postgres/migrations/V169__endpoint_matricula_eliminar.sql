-- =============================================================================
-- V169 -- Registra en el catalogo `query` los dos endpoints de baja de
-- matricula, contraparte del POST de alta (V167) y del GET (V168):
--
--   PUT  /cobertura-academica/matricula/:ID          -> fn_matricula_directa_eliminar
--   POST /cobertura-academica/matricula/bulk-delete  -> fn_matricula_directa_eliminar_bulk
--
-- POR QUE PUT Y NO DELETE: el catalogo lo impide. La tabla `query` tiene un
-- CHECK (ck_query_http_method) que solo admite GET/POST/PUT/PATCH, asi que
-- DELETE no se puede registrar. No es una limitacion accidental: TODO el
-- sistema da de baja por PUT -- /establecimientos/:ID, /establecimientos/
-- sedes/:ID, /establecimientos/funcionarios/:ID, /periodo-evaluacion/:ID,
-- /grados/:ID/eliminar. Estas dos rutas siguen esa convencion.
--
-- PUT sobre /cobertura-academica/matricula/:ID convive con el GET de V168 en
-- la misma ruta: el indice unico del catalogo es por (microservicio, ruta,
-- metodo), asi que son dos filas distintas.
--
-- El masivo va por POST, como las otras 5 rutas .../bulk-delete del catalogo
-- (escalas, establecimientos, grupos, periodo-evaluacion, plan-asignaturas):
-- el cuerpo lleva el array de PKs.
--
-- Ninguno pasa por file-service: no hay binarios en la peticion. La baja de
-- los enlaces de archivo (TMATRICULA_ARCHIVO) es logica y no toca S3 -- ver
-- fn_matricula_archivo_soft_delete (V165).
--
-- Sin fila en role_query ambas responden 403 -- los permisos por rol se
-- configuran aparte, en la plataforma.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Baja individual
-- ---------------------------------------------------------------------------
INSERT INTO public.query (
    uuid, query, type, public_end, captcha, microservice_id,
    path_template, execution_mode, http_method, param_types, detail
)
SELECT
    'q-mtb2d9k4-cobmatdel1',
    'SELECT academico_test.fn_matricula_directa_eliminar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS resultado;',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/:ID', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V169 -- baja logica de una matricula: valida dependencias bloqueantes, arrastra socioeconomico y archivos, y resuelve estudiante/acudiente/usuario segun sus otros usos'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query,
       param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template,
       http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode,
       microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;

-- ---------------------------------------------------------------------------
-- 2. Baja masiva
--
-- :BODY_RAW.IDS llega como JSONB (un array de numeros) y se convierte a
-- BIGINT[] con jsonb_array_elements_text -- mismo patron BODY_RAW + CAST que
-- ya usan fn_subject_guardar_bulk y los permisos de funcionario. No se usa
-- :BODY.IDS porque el motor aplanaria el array.
-- ---------------------------------------------------------------------------
INSERT INTO public.query (
    uuid, query, type, public_end, captcha, microservice_id,
    path_template, execution_mode, http_method, param_types, detail
)
SELECT
    'q-mtb2d9k4-cobmatdel2',
    'SELECT * FROM academico_test.fn_matricula_directa_eliminar_bulk(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    ARRAY(SELECT jsonb_array_elements_text(CAST(:BODY_RAW.IDS AS JSONB))::BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/bulk-delete', 'SELECT', 'POST',
    '{"BODY_RAW.IDS": "JSONB"}'::jsonb,
    'V169 -- baja logica masiva de matriculas: procesa cada PK por separado y devuelve status y detalle por cada una; una que falle no detiene las demas'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET query = EXCLUDED.query,
       param_types = EXCLUDED.param_types,
       path_template = EXCLUDED.path_template,
       http_method = EXCLUDED.http_method,
       execution_mode = EXCLUDED.execution_mode,
       microservice_id = EXCLUDED.microservice_id,
       detail = EXCLUDED.detail;
