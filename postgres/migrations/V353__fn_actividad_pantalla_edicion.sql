-- V353 - Alta de GET /planeador/actividades/:ID/pantalla-edicion con los roles
-- de GET /planeador/actividades/:ID. La función vive en V452 y la fila la
-- define hoy V496.4.


SET search_path TO public;

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action,
     style, cacheable, cache_ttl_seconds)
SELECT
    'q-planeador-actividad-pantalla-edicion',
    'SELECT academico_test.fn_actividad_pantalla_edicion(
        public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
        CAST(:PARAM.ID AS BIGINT),
        COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2)
    ) AS pantalla',
    'postgres', false, false,
    m.id_microservice,
    '/planeador/actividades/:ID/pantalla-edicion', 'SELECT', 'GET',
    '{"PARAM.ID": "BIGINT", "QUERY.DIAS_GRACIA": "INTEGER"}'::jsonb,
    NULL,
    'V353 -- DTO compuesto para PlaneadorEditarActividadPage: actividad + instrumento en una sola llamada, ya en camelCase y anidado por concepto. Reemplaza, PARA ESA PANTALLA, la cadena GET .../:ID + GET .../:ID/instrumento. Incluye ademas evidencias (TACTIVIDAD_EVIDENCIA: [{pk, fkReferenteEnunciado, texto, fkPadre, textoPadre}]) y criterios (TACTIVIDAD_CRITERIO_UNIDAD: [{pk, fkTcriterioUnidad, descripcion, codigo, orden}]) ya relacionados, para poder pre-marcarlos al reabrir la actividad y para conocer el pk que exigen PATCH /planeador/actividades/evidencias/:ID y PATCH /planeador/actividades/criterios/:ID.',
    NULL,
    NULL,
    false, 60
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT rq.role_id, q_new.id_query
  FROM public.role_query rq
  JOIN public.query q_old ON q_old.path_template = '/planeador/actividades/:ID'
                          AND q_old.http_method = 'GET'
                          AND q_old.id_query = rq.query_id
  JOIN public.query q_new ON q_new.uuid = 'q-planeador-actividad-pantalla-edicion'
 WHERE NOT EXISTS (
     SELECT 1 FROM public.role_query rq2
      WHERE rq2.query_id = q_new.id_query AND rq2.role_id = rq.role_id
 );
