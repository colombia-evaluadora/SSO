-- V531.4 - Validación de la ACTIVIDAD por el Coordinador, capa 4 de 4: endpoints.
-- GET (estado + puedeValidar) para todos los roles que ven el planeador (V249,
-- V494, V533); POST (aprobar/declinar) para los roles aprobadores de V496.21.
-- Upsert por (microservicio, ruta, método), como V496.21.
-- Depende de: V531.3, V249/V494 (roles del planeador).

SET search_path TO academico_test, public;

-- GET /planeador/actividades/:ID/validacion-coordinador
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '7c1f9b8e-4a2d-4f6b-9b51-3d0e6a2c8f11', m.id_microservice, '/planeador/actividades/:ID/validacion-coordinador', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT"}'::jsonb,
       'Estado de la validación de la actividad :ID por el Coordinador (fn_actividad_validacion_coordinador_consultar): {pkActividad, requiereValidacion, estado (NO_REQUIERE|PENDIENTE|APROBADA|DECLINADA), observacion, validadoPor, fechaValidacion, puedeValidar}. puedeValidar es TRUE si el usuario es Coordinador de la sede de la actividad (o Rector, Jefe de sistema o Auxiliar administrativo de su establecimiento) y no la planeó. Errores: 404 (P0002) si no existe; 403 (42501) sin VER del planeador sobre la actividad.',
       $q$SELECT academico_test.fn_actividad_validacion_coordinador_consultar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT)
) AS resultado;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /planeador/actividades/:ID/validacion-coordinador
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'b4e2d7a1-9c3f-4e8a-8d26-5f1a0c7e9b42', m.id_microservice, '/planeador/actividades/:ID/validacion-coordinador', 'POST', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "BODY.DECISION": "VARCHAR", "BODY.OBSERVACION": "VARCHAR"}'::jsonb,
       'El Coordinador de la sede aprueba o declina la planeación de la actividad :ID (fn_actividad_validacion_coordinador_resolver). BODY.DECISION APROBADA o DECLINADA; BODY.OBSERVACION opcional al aprobar y obligatoria al declinar (≤1000). Reemplaza la decisión vigente. Devuelve el mismo objeto que el GET (sin puedeValidar). Errores: 404 (P0002) si no existe; 400 (22023) si está eliminada, no requiere validación, la decisión es inválida o falta la observación; 403 (42501) si no es Coordinador de la sede de la actividad o si la planeó él mismo.',
       $q$SELECT academico_test.fn_actividad_validacion_coordinador_resolver(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.DECISION AS VARCHAR),
    CAST(:BODY.OBSERVACION AS VARCHAR)
) AS resultado;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.role r ON r.name IN ('CEVAL-DOCENTE', 'CEVAL-SUPER_ADMINISTRADOR', 'CEVAL-RECTOR',
                                   'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO', 'CEVAL-JEFE_SISTEMA_ENTE_TERRITORIAL',
                                   'CEVAL-COORDINADOR', 'CEVAL-PSICO_ORIENTADOR', 'CEVAL-DIRECTOR_GRUPO',
                                   'CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-JEFE_AREA_CALIDAD',
                                   'CEVAL-JEFE_AREA_COBERTURA', 'CEVAL-JEFE_AREA_PLANEACION')
 WHERE q.http_method = 'GET' AND q.path_template = '/planeador/actividades/:ID/validacion-coordinador'
ON CONFLICT DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.role r ON r.name IN ('CEVAL-COORDINADOR', 'CEVAL-RECTOR', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
                                   'CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-SUPER_ADMINISTRADOR')
 WHERE q.http_method = 'POST' AND q.path_template = '/planeador/actividades/:ID/validacion-coordinador'
ON CONFLICT DO NOTHING;
