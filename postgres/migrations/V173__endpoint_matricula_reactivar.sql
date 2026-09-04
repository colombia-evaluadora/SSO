-- =============================================================================
-- V173 -- Registra en el catalogo `query` el endpoint de reactivacion de
-- matricula, tercera accion de cambio de estado del modulo junto al retiro
-- (V171) y el reingreso (V172):
--
--   PUT /cobertura-academica/matricula/:ID/reactivar -> fn_matricula_reactivar
--
-- Reactivar != reingresar. El reingreso saca de "Retirado" (el estudiante se
-- fue y vuelve); la reactivacion saca de un estado de CIERRE ACADEMICO
-- (Aprobado, Reprobado, Promovido, Reubicado) para corregir o completar
-- informacion antes del cierre definitivo. Por eso son endpoints separados y
-- no uno solo con el estado como parametro: cada uno tiene su propio conjunto
-- de estados de origen y su propio significado de negocio.
--
-- Mismo criterio que V171/V172: PUT y ruta con sufijo propio (el indice unico
-- del catalogo es por microservicio + ruta + metodo).
--
-- Sin cuerpo: solo el ID. Sin restriccion temporal -- se puede reactivar una
-- matricula de cualquier año lectivo, incluso cerrado.
--
-- Igual que las otras dos, el gate NO acepta a un super-admin por su
-- condicion de tal: solo rector, secretaria o jefe de sistema del
-- establecimiento de la matricula.
--
-- Sin fila en role_query responde 403 -- los permisos por rol se configuran
-- aparte, en la plataforma.
-- =============================================================================

INSERT INTO public.query (
    uuid, query, type, public_end, captcha, microservice_id,
    path_template, execution_mode, http_method, param_types, detail
)
SELECT
    'q-mtb2d9k4-cobmatrea1',
    'SELECT academico_test.fn_matricula_reactivar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS resultado;',
    'postgres', false, false,
    m.id_microservice,
    '/cobertura-academica/matricula/:ID/reactivar', 'SELECT', 'PUT',
    '{"PARAM.ID": "BIGINT"}'::jsonb,
    'V173 -- reactivacion de matricula: devuelve a Cursando una matricula cerrada academicamente (Aprobado, Reprobado, Promovido, Reubicado) para corregir o completar informacion. Solo rector/secretaria/jefe de sistema del establecimiento; el super-admin NO puede ejecutarlo'
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
