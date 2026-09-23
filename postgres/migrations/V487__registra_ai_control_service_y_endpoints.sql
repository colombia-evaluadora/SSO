-- ===========================================================================
-- V487 - Registra ai-control-service y sus endpoints en el catalogo del SSO
-- Que hace: fila REST en public.microservice (la ruta real es estatica en el
--   gateway, como reporting-service en V68), los dos endpoints en
--   public.endpoint y sus roles en role_endpoint.
-- Por que esos roles: los endpoints generan Y guardan, asi que se copian de
--   los /guardar de informes; un rol solo de lectura pasaria aqui y chocaria
--   con el 403 del guardado despues de gastar la llamada al modelo.
-- Depende de: V343 (/informes/observacion/guardar), V435 (/final/guardar).
-- ===========================================================================

-- La secuencia puede ir atras de los ids sembrados a mano (ver V68).
SELECT setval(
    pg_get_serial_sequence('public.microservice', 'id_microservice'),
    (SELECT COALESCE(MAX(id_microservice), 1) FROM public.microservice),
    TRUE
);

INSERT INTO public.microservice (serviceid, description, requesturi, kind)
SELECT 'ai-control-service',
       'Endpoints de IA: resumenes de observaciones de preescolar redactados por un modelo compatible con OpenAI (NVIDIA NIM)',
       '/api/ai/**',
       'REST'
 WHERE NOT EXISTS (
     SELECT 1 FROM public.microservice WHERE serviceid = 'ai-control-service'
 );

-- El UNIQUE de endpoint incluye la descripcion: sin el DELETE previo, editar
-- el texto aqui dejaria dos filas del mismo (method, path). El CASCADE limpia
-- endpoint_microservice y role_endpoint, que se reconstruyen abajo.
DELETE FROM public.endpoint
 WHERE (method, path) IN (('POST', '/ai/observaciones/periodo'),
                          ('POST', '/ai/observaciones/anio'));

INSERT INTO public.endpoint (method, path, description, numberparams, param_types)
VALUES ('POST', '/ai/observaciones/periodo',
        'Genera con IA y guarda el resumen de observaciones de un estudiante en un periodo de evaluacion. Body: FK_TMATRICULA, FK_TPERIODO_EVALUACION, SOBRESCRIBIR',
        0,
        '{"BODY.FK_TMATRICULA": "BIGINT", "BODY.FK_TPERIODO_EVALUACION": "BIGINT", "BODY.SOBRESCRIBIR": "BOOLEAN"}'::jsonb),
       ('POST', '/ai/observaciones/anio',
        'Genera con IA y guarda el consolidado del ano de un estudiante a partir de sus resumenes de periodo. Body: FK_TMATRICULA, SOBRESCRIBIR',
        0,
        '{"BODY.FK_TMATRICULA": "BIGINT", "BODY.SOBRESCRIBIR": "BOOLEAN"}'::jsonb);

INSERT INTO public.endpoint_microservice (endpoint_id, microservice_id)
SELECT e.id_endpoint, m.id_microservice
  FROM public.endpoint e
  JOIN public.microservice m ON m.serviceid = 'ai-control-service'
 WHERE (e.method, e.path) IN (('POST', '/ai/observaciones/periodo'),
                              ('POST', '/ai/observaciones/anio'))
ON CONFLICT DO NOTHING;

INSERT INTO public.role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, rq.role_id
  FROM public.endpoint e
  JOIN public.query q
    ON q.http_method   = 'POST'
   AND q.path_template = CASE e.path
                             WHEN '/ai/observaciones/periodo' THEN '/informes/observacion/guardar'
                             WHEN '/ai/observaciones/anio'    THEN '/informes/observacion/final/guardar'
                         END
  JOIN public.microservice mq ON mq.id_microservice = q.microservice_id
                             AND mq.serviceid       = 'eval-col'
  JOIN public.role_query rq   ON rq.query_id = q.id_query
 WHERE e.method = 'POST'
   AND e.path IN ('/ai/observaciones/periodo', '/ai/observaciones/anio')
ON CONFLICT DO NOTHING;
