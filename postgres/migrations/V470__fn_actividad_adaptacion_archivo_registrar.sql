-- V470 - Alta de POST /planeador/actividades/:ID/adaptaciones/archivo con los
-- roles de PUT :ID/adaptaciones. La función y la fila viven hoy en V496.3/V496.4.


INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-actividad-adaptacion-archivo-001',
    'SELECT academico_test.fn_actividad_adaptacion_archivo_registrar(
    p_pk_usuario_solicitante => public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    p_pk_tactividad          => CAST(:PARAM.ID AS BIGINT),
    p_fk_tarchivo            => CAST(:BODY.ARCHIVO AS BIGINT)
) AS fk_tarchivo;',
    'postgres', false, false,
    m.id_microservice,
    '/planeador/actividades/:ID/adaptaciones/archivo', 'SELECT', 'POST',
    '{"PARAM.ID": "BIGINT", "BODY.ARCHIVO": "FILE:actividad"}'::jsonb,
    NULL,
    'V470 -- paso 1 del flujo de adaptaciones curriculares (formatoAdaptacion = ARCHIVO o BIBLIOTECA): sube UN archivo (multipart, campo ARCHIVO) a POST /files/eval-col/planeador/actividades/<id>/adaptaciones/archivo y devuelve su fk_tarchivo, que luego se manda como el fkTarchivo del elemento correspondiente en PUT /planeador/actividades/<id>/adaptaciones (paso 2). Mismo patron que /materiales/archivo (V426): un archivo por peticion, no enlaza nada (la lista la escribe el PUT, reemplazo total). Responde 42501 si el usuario no puede editar esa actividad, 404 si no existe y 409 si el archivo no quedo registrado.',
    'actividad-adaptacion-archivo', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (query_id, role_id)
SELECT nuevo.id_query, rq.role_id
  FROM public.query nuevo
  JOIN public.query hermano
    ON hermano.microservice_id = nuevo.microservice_id
   AND hermano.path_template   = '/planeador/actividades/:ID/adaptaciones'
   AND hermano.http_method     = 'PUT'
  JOIN public.role_query rq ON rq.query_id = hermano.id_query
 WHERE nuevo.uuid = 'eval-col-actividad-adaptacion-archivo-001'
ON CONFLICT DO NOTHING;
