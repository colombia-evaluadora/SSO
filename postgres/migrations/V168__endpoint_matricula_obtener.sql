-- =============================================================================
-- V168 -- Registra en el catalogo `query` el GET de una matricula completa:
-- GET /cobertura-academica/matricula/:ID -> fn_matricula_obtener_completa
-- (V166), la contraparte de lectura del POST registrado en V167.
--
-- A diferencia del POST, este NO pasa por file-service: no hay binarios en
-- la peticion ni en la respuesta. La funcion devuelve los pk_tarchivo de
-- los documentos de soporte, y el front los pide despues a file-service
-- (GET /files/download/{id} o el flujo de view-token).
--
-- La funcion devuelve un unico JSONB con todo el arbol
-- (matricula/socioeconomico/estudiante/acudientes/archivos), no una tabla
-- ancha: el resultado tiene listas anidadas (acudientes, archivos) que no
-- caben en un RETURNS TABLE plano sin repetir la matricula por cada fila.
-- El alias `matricula` nombra esa unica columna del resultado.
--
-- Devuelve NULL (columna en null) si la matricula no existe, esta
-- inactiva, o su cadena grupo/grado/periodo/sede tiene un eslabon
-- inactivo -- el front lo trata como 404. Si el usuario no tiene alcance
-- sobre la sede de esa matricula, la funcion lanza 42501 (gate estricto,
-- ver V163).
--
-- Sin fila en role_query esta query responde 403 a cualquier caller -- los
-- permisos por rol se configuran aparte, en la plataforma.
-- =============================================================================

INSERT INTO public.query (
    uuid, query, type, public_end, captcha, microservice_id,
    path_template, execution_mode, http_method, param_types, detail
)
SELECT
    'q-mtb2d9k4-cobmatg1',
    'SELECT academico_test.fn_matricula_obtener_completa(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS matricula;',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/:ID', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V168 -- matricula completa por ID (matricula + socioeconomico + estudiante + acudientes + archivos de soporte) para el detalle/edicion del formulario de matricula'
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
