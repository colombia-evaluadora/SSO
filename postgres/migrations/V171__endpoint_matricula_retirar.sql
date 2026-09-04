-- =============================================================================
-- V171 -- Registra en el catalogo `query` el endpoint de retiro de matricula:
--
--   PUT /cobertura-academica/matricula/:ID/retirar -> fn_matricula_retirar
--
-- Va por PUT, como el resto de las acciones de cambio de estado del catalogo
-- (la tabla `query` tiene un CHECK que solo admite GET/POST/PUT/PATCH, y todo
-- el sistema usa PUT para este tipo de operacion -- ver V169).
--
-- La ruta lleva el sufijo /retirar y no reusa PUT /cobertura-academica/
-- matricula/:ID, que ya esta tomado por la BAJA (V169): son dos acciones
-- distintas sobre el mismo recurso -- una da de baja la matricula, la otra
-- solo le cambia el estado a "Retirado" conservando toda su informacion.
-- El indice unico del catalogo es por (microservicio, ruta, metodo), asi que
-- ademas necesitan rutas distintas para poder convivir con el mismo verbo.
--
-- Sin cuerpo: el retiro no recibe nada mas que el ID.
--
-- OJO con el gate: a diferencia del resto del modulo, fn_matricula_retirar
-- NO acepta a un super-admin por su condicion de tal -- solo rector,
-- secretaria o jefe de sistema del establecimiento de la matricula. Ver la
-- cabecera de esa funcion en V166.
--
-- Sin fila en role_query responde 403 -- los permisos por rol se configuran
-- aparte, en la plataforma.
-- =============================================================================

INSERT INTO public.query (
    uuid, query, type, public_end, captcha, microservice_id,
    path_template, execution_mode, http_method, param_types, detail
)
SELECT
    'q-mtb2d9k4-cobmatret1',
    'SELECT academico_test.fn_matricula_retirar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS resultado;',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/:ID/retirar', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V171 -- retiro de matricula: cambia el estado de Cursando a Retirado conservando toda la informacion. Solo rector/secretaria/jefe de sistema del establecimiento; el super-admin NO puede ejecutarlo'
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
