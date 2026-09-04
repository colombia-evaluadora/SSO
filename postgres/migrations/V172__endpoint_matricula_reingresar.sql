-- =============================================================================
-- V172 -- Registra en el catalogo `query` el endpoint de reingreso de
-- matricula, contraparte del retiro (V171):
--
--   PUT /cobertura-academica/matricula/:ID/reingresar -> fn_matricula_reingresar
--
-- Mismo criterio que V171: PUT (la tabla `query` solo admite
-- GET/POST/PUT/PATCH, y todo el sistema usa PUT para cambios de estado), y
-- ruta con sufijo propio para convivir con las otras acciones del mismo
-- recurso -- el indice unico del catalogo es por (microservicio, ruta,
-- metodo).
--
-- Sin cuerpo: el reingreso no recibe nada mas que el ID.
--
-- Igual que el retiro, el gate de fn_matricula_reingresar NO acepta a un
-- super-admin por su condicion de tal: solo rector, secretaria o jefe de
-- sistema del establecimiento de la matricula.
--
-- Sin fila en role_query responde 403 -- los permisos por rol se configuran
-- aparte, en la plataforma.
-- =============================================================================

INSERT INTO public.query (
    uuid, query, type, public_end, captcha, microservice_id,
    path_template, execution_mode, http_method, param_types, detail
)
SELECT
    'q-mtb2d9k4-cobmatrei1',
    'SELECT academico_test.fn_matricula_reingresar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS resultado;',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/:ID/reingresar', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V172 -- reingreso de matricula: cambia el estado de Retirado a Cursando y cierra el registro de retiro llenando su FECHA_REINTEGRO. Solo rector/secretaria/jefe de sistema del establecimiento; el super-admin NO puede ejecutarlo'
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
