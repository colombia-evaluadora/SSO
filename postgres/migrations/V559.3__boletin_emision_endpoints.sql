-- V559.3 — Verificación del boletín por QR: endpoints.
--
-- Qué hace: registrar y revocar emisiones (autenticados, roles del listado de
-- informes) y las dos lecturas públicas por uuid, sin ruta, que reporting-service
-- llama por /public/service sin token de usuario.
-- Depende de: V559.2 (wrappers), V540 (fila hermana /informes/grupo).

INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT v.uuid, m.id_microservice, v.ruta, 'POST', 'postgres', 'SELECT', NULL,
       'false', 'false', 'false', '60', v.accion, 'DEFAULT', v.tipos::jsonb, v.detalle, v.sql
  FROM public.microservice m
 CROSS JOIN (VALUES
    ('eval-col-boletin-emisiones-registrar-001', '/informes/boletin-emisiones/registrar',
     'boletin-emisiones-registrar',
     '{"BODY.FK_TGRUPO": "BIGINT!", "BODY.FK_TPERIODO_EVALUACION": "BIGINT!", "BODY.NIVEL": "TEXT!", "BODY.FK_TMATRICULAS": "BIGINT[]"}',
     'Registra el boletin impreso de cada estudiante del grupo (o de FK_TMATRICULAS) y devuelve su CODIGO de verificacion por CLAVE de la plantilla. Lo llama reporting-service al generar el boletin.',
     $q$SELECT * FROM academico_test.fn_boletin_emision_registrar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.FK_TGRUPO AS BIGINT),
    CAST(:BODY.FK_TPERIODO_EVALUACION AS BIGINT),
    CAST(:BODY.NIVEL AS VARCHAR),
    CAST(:BODY.FK_TMATRICULAS AS BIGINT[])
);$q$),
    ('eval-col-boletin-emisiones-revocar-001', '/informes/boletin-emisiones/revocar',
     'boletin-emisiones-revocar',
     '{"BODY.CODIGO": "TEXT!", "BODY.MOTIVO": "TEXT!"}',
     'Revoca la emision de un boletin por su CODIGO de QR; desde entonces la verificacion publica responde NO_VALIDO. Rector o administracion del establecimiento.',
     $q$SELECT * FROM academico_test.fn_boletin_emision_revocar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:BODY.CODIGO AS VARCHAR),
    CAST(:BODY.MOTIVO AS VARCHAR)
);$q$)
 ) AS v(uuid, ruta, accion, tipos, detalle, sql)
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method) WHERE path_template IS NOT NULL DO UPDATE
   SET uuid = EXCLUDED.uuid, type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;

-- Quien ve el listado de informes puede imprimir boletines; revocar lo decide el gate.
INSERT INTO public.role_query (role_id, query_id)
SELECT rq.role_id, q.id_query
  FROM public.query q
  JOIN public.microservice m ON m.id_microservice = q.microservice_id AND m.serviceid = 'eval-col'
  JOIN public.query listado ON listado.microservice_id = q.microservice_id
                           AND listado.path_template = '/informes/grupo' AND listado.http_method = 'POST'
  JOIN public.role_query rq ON rq.query_id = listado.id_query
 WHERE q.path_template IN ('/informes/boletin-emisiones/registrar', '/informes/boletin-emisiones/revocar')
   AND q.http_method = 'POST'
ON CONFLICT DO NOTHING;

-- Publicas: sin ruta (solo /public/service), sin cache de resultados y sin
-- role_query. El gate es el CODIGO (y los 4 digitos para los datos).
INSERT INTO public.query (uuid, microservice_id, path_template, http_method, type, execution_mode, out_param_names,
                          public_end, captcha, cacheable, cache_ttl_seconds, action, style, param_types, detail, query)
SELECT v.uuid, m.id_microservice, NULL, 'POST', 'postgres', 'SELECT', NULL,
       'true', 'false', 'false', '60', v.accion, 'DEFAULT', v.tipos::jsonb, v.detalle, v.sql
  FROM public.microservice m
 CROSS JOIN (VALUES
    ('eval-col-boletin-verificacion-consultar-001', 'boletin-verificacion-consultar',
     '{"BODY.CODIGO": "TEXT!"}',
     'Publica: estado de un codigo de QR de boletin (VIGENTE, ACTUALIZADO o REEMPLAZADO), fechas, establecimiento, sede y periodo. Sin datos del estudiante.',
     $q$SELECT * FROM academico_test.fn_boletin_verificacion_consultar(CAST(:BODY.CODIGO AS VARCHAR));$q$),
    ('eval-col-boletin-verificacion-datos-001', 'boletin-verificacion-datos',
     '{"BODY.CODIGO": "TEXT!", "BODY.ULTIMOS4": "TEXT!"}',
     'Publica: datos actuales del boletin de un codigo de QR, solo si ULTIMOS4 coincide con el documento del estudiante. Para regenerar el PDF de verificacion.',
     $q$SELECT * FROM academico_test.fn_boletin_verificacion_datos(CAST(:BODY.CODIGO AS VARCHAR), CAST(:BODY.ULTIMOS4 AS VARCHAR));$q$)
 ) AS v(uuid, accion, tipos, detalle, sql)
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (uuid) DO UPDATE
   SET path_template = NULL, type = EXCLUDED.type, execution_mode = EXCLUDED.execution_mode,
       public_end = EXCLUDED.public_end, captcha = EXCLUDED.captcha, cacheable = EXCLUDED.cacheable,
       cache_ttl_seconds = EXCLUDED.cache_ttl_seconds, action = EXCLUDED.action, style = EXCLUDED.style,
       param_types = EXCLUDED.param_types, detail = EXCLUDED.detail, query = EXCLUDED.query;
