-- V496.21 - Aprobación del Coordinador, capa 4 de 4: endpoints. Pendientes,
-- aprobar y rechazar (una o en lote) para CEVAL-COORDINADOR, CEVAL-RECTOR, CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO,
-- CEVAL-AUXILIAR_ADMINISTRATIVO y CEVAL-SUPER_ADMINISTRADOR; la
-- marca de informe desactualizado con los roles de /informes/grupo. Las filas
-- de calificar y de registrar o editar asistencia suman solicitudes_pendientes: la
-- escritura no falla cuando exige aprobación, devuelve qué solicitud abrió.
-- Upsert por (microservicio, ruta, método), como V496.8.
-- Depende de: V496.20, V496.8, V221 y V438 (filas que se envuelven), V342.

SET search_path TO academico_test, public;

-- GET /aprobaciones/pendientes
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'a88692e0-a70e-438e-8ed9-9f8e3b30eb71', m.id_microservice, '/aprobaciones/pendientes', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"QUERY.TIPO": "VARCHAR", "QUERY.GRUPO": "BIGINT", "QUERY.ESTADO": "VARCHAR"}'::jsonb,
       'Solicitudes de aprobación que el Coordinador puede resolver (fn_solicitud_aprobacion_listar; Regla 70): las de los grupos de las sedes donde es Coordinador, o todas para el super administrador. ?tipo= RECUPERACION_HABILITACION, RECUPERACION_REFUERZO, CORRECCION_RESULTADO o CORRECCION_ASISTENCIA; ?grupo= PK_TGRUPO; ?estado= PENDIENTE (por defecto), APROBADA o RECHAZADA. Cada fila trae grupo, asignatura, periodo, actividad, estudiante, valor_anterior y valor_propuesto, solicitante y fechas; en asistencia, además fk_tmatricula, fecha y bloque de la sesión. Errores: 403 (42501) si no es Coordinador en ninguna sede.',
       $q$SELECT * FROM academico_test.fn_solicitud_aprobacion_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.TIPO AS VARCHAR),
    CAST(:QUERY.GRUPO AS BIGINT),
    COALESCE(CAST(:QUERY.ESTADO AS VARCHAR), 'PENDIENTE')
);$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /aprobaciones/:ID/aprobar
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '34938f29-f0b7-4326-95d2-0d1b9b35b43b', m.id_microservice, '/aprobaciones/:ID/aprobar', 'POST', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "BODY.MOTIVO": "VARCHAR"}'::jsonb,
       'Aprueba la solicitud :ID (fn_solicitud_aprobacion_aprobar) y aplica el cambio: la recuperación se consolida, la corrección de resultado o de asistencia se escribe. BODY.MOTIVO opcional (≤1000). Si el informe del grupo y periodo ya se había emitido queda desactualizado (Regla 71). Devuelve {pkSolicitud, estado, tipo, resultado, informeDesactualizado}. Errores: 404 (P0002) si no existe; 400 (22023) si ya fue resuelta o el motivo excede 1000; 403 (42501) si no es Coordinador de la sede del grupo.',
       $q$SELECT academico_test.fn_solicitud_aprobacion_aprobar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.MOTIVO AS VARCHAR)
) AS resultado;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /aprobaciones/:ID/rechazar
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '5d789d1c-f31d-45b5-9fd6-c67e1b9bb530', m.id_microservice, '/aprobaciones/:ID/rechazar', 'POST', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"PARAM.ID": "BIGINT", "BODY.MOTIVO": "VARCHAR"}'::jsonb,
       'Rechaza la solicitud :ID (fn_solicitud_aprobacion_rechazar); el valor vigente no cambia (Regla 70). BODY.MOTIVO obligatorio (≤1000). Devuelve {pkSolicitud, estado, valorVigente}. Errores: 404 (P0002) si no existe; 400 (22023) si ya fue resuelta o falta el motivo; 403 (42501) si no es Coordinador de la sede del grupo.',
       $q$SELECT academico_test.fn_solicitud_aprobacion_rechazar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:PARAM.ID AS BIGINT),
    CAST(:BODY.MOTIVO AS VARCHAR)
) AS resultado;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- GET /informes/desactualizado
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '50f1753f-2add-4313-8b07-e2c58b83930e', m.id_microservice, '/informes/desactualizado', 'GET', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"QUERY.GRUPO": "BIGINT", "QUERY.PERIODO": "BIGINT"}'::jsonb,
       'Advertencia de la Regla 71 para el informe del grupo ?grupo= en el periodo de evaluación ?periodo= (fn_informe_desactualizado): {desactualizado, mensaje, cambios[]} cuando una aprobación cambió valores después de emitirlo. Se limpia al volver a guardar el informe. Errores: 404 (P0002) si el grupo no existe; 403 (42501) sin alcance sobre el grupo.',
       $q$SELECT academico_test.fn_informe_desactualizado(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.PERIODO AS BIGINT)
) AS informe;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /aprobaciones/aprobar-masivo
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT 'c4b3d9e9-2a8f-450d-801f-0b0b84bd6f20', m.id_microservice, '/aprobaciones/aprobar-masivo', 'POST', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"BODY.IDS": "BIGINT[]", "BODY.MOTIVO": "VARCHAR"}'::jsonb,
       'Aprueba las solicitudes BODY.IDS (hasta 500) en una llamada (fn_solicitud_aprobacion_resolver_masivo): cada una como POST /aprobaciones/:ID/aprobar, y la que falla no frena a las demás. BODY.MOTIVO opcional (≤1000). Devuelve resultado = {resueltas: [pk], fallidas: [{id, codigo, error}]}. Errores del lote: 400 (22023) si IDS viene vacío, pasa de 500 o el motivo excede 1000.',
       $q$SELECT academico_test.fn_solicitud_aprobacion_resolver_masivo(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    TRUE,
    CAST(:BODY.IDS AS BIGINT[]),
    CAST(:BODY.MOTIVO AS VARCHAR)
) AS resultado;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- POST /aprobaciones/rechazar-masivo
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT '39733258-a13e-464b-8e86-cc5701d879fc', m.id_microservice, '/aprobaciones/rechazar-masivo', 'POST', 'postgres', 'SELECT', NULL,
       'f', 'f', 'f', '60', NULL, NULL,
       '{"BODY.IDS": "BIGINT[]", "BODY.MOTIVO": "VARCHAR"}'::jsonb,
       'Rechaza las solicitudes BODY.IDS (hasta 500) en una llamada (fn_solicitud_aprobacion_resolver_masivo): cada una como POST /aprobaciones/:ID/rechazar, y la que falla no frena a las demás. BODY.MOTIVO obligatorio (≤1000), el mismo para todas. Devuelve resultado = {resueltas: [pk], fallidas: [{id, codigo, error}]}. Errores del lote: 400 (22023) si IDS viene vacío, pasa de 500 o falta el motivo.',
       $q$SELECT academico_test.fn_solicitud_aprobacion_resolver_masivo(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    FALSE,
    CAST(:BODY.IDS AS BIGINT[]),
    CAST(:BODY.MOTIVO AS VARCHAR)
) AS resultado;$q$
  FROM public.microservice m WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode, out_param_names = EXCLUDED.out_param_names,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- Registrar y editar asistencia (las filas de calificar se envuelven en V496.8, su dueña):
-- la escritura no cambia, se le suma la solicitud que abrió. MATERIALIZED garantiza que la función ya corrió cuando
-- se lee la lista. El guard por prefijo hace el UPDATE idempotente.
UPDATE public.query q
   SET query = 'WITH w AS MATERIALIZED (' || regexp_replace(q.query, ';\s*$', '')
               || E')\nSELECT w.*, academico_test.fn_solicitud_aprobacion_creadas() AS solicitudes_pendientes FROM w;',
       detail = q.detail || ' Si el cambio exige aprobación del Coordinador (Reglas 55, 69, 75) no se aplica todavía: solicitudes_pendientes trae el PK de la solicitud abierta (vacío = se aplicó).'
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
   AND q.query NOT LIKE 'WITH w AS MATERIALIZED (%'
   AND (q.http_method, q.path_template) IN (('PATCH', '/asistencias/:ID'),
                                            ('POST', '/asistencias/registrar'),
                                            ('POST', '/asistencias/editar-masivo'));

INSERT INTO public.role_query (role_id, query_id)
SELECT r.id_role, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.role r ON r.name IN ('CEVAL-COORDINADOR', 'CEVAL-RECTOR', 'CEVAL-JEFE_SISTEMA_ESTABLECIMIENTO',
                                   'CEVAL-AUXILIAR_ADMINISTRATIVO', 'CEVAL-SUPER_ADMINISTRADOR')
 WHERE (q.http_method, q.path_template) IN (
        ('GET',  '/aprobaciones/pendientes'),
        ('POST', '/aprobaciones/:ID/aprobar'),
        ('POST', '/aprobaciones/:ID/rechazar'),
        ('POST', '/aprobaciones/aprobar-masivo'),
        ('POST', '/aprobaciones/rechazar-masivo'))
ON CONFLICT DO NOTHING;

INSERT INTO public.role_query (role_id, query_id)
SELECT rq.role_id, nueva.id_query
  FROM public.role_query rq
  JOIN public.query origen ON origen.id_query = rq.query_id
                          AND origen.http_method = 'POST' AND origen.path_template = '/informes/grupo'
  JOIN public.microservice m ON m.id_microservice = origen.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.query nueva ON nueva.microservice_id = m.id_microservice
                         AND nueva.http_method = 'GET' AND nueva.path_template = '/informes/desactualizado'
ON CONFLICT DO NOTHING;
