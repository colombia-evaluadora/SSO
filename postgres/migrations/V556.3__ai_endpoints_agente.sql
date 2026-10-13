-- V556.3 -- Endpoints del agente en el catalogo: /ai/agente/** (ai-control-service)
-- Que hace: registra 8 endpoints en public.endpoint, su microservicio y sus roles.
--   Roles: todos los CEVAL-<TROL.CODIGO> con al menos un menu activo, por consulta.
-- Por que aqui: patron de V487. No hay DELETE de conversaciones: se archivan.
-- Depende de: V487 (microservice ai-control-service), academico_test.trol y trol_menu.

DELETE FROM public.endpoint
 WHERE (method, path) IN (('POST',   '/ai/agente/conversaciones'),
                          ('GET',    '/ai/agente/conversaciones'),
                          ('GET',    '/ai/agente/conversaciones/{id}'),
                          ('PUT',    '/ai/agente/conversaciones/{id}/archivar'),
                          ('POST',   '/ai/agente/conversaciones/{id}/mensajes'),
                          ('POST',   '/ai/agente/conversaciones/{id}/mensajes/stream'),
                          ('POST',   '/ai/agente/acciones/{id}/confirmar'),
                          ('POST',   '/ai/agente/acciones/{id}/cancelar'));

INSERT INTO public.endpoint (method, path, description, numberparams, param_types)
VALUES ('POST', '/ai/agente/conversaciones',
        'Crea una conversacion del agente para el usuario del token', 0, '{}'::jsonb),
       ('GET', '/ai/agente/conversaciones',
        'Lista las conversaciones del usuario, mas recientes primero', 2,
        '{"QUERY.PAGE": "INTEGER", "QUERY.SIZE": "INTEGER"}'::jsonb),
       ('GET', '/ai/agente/conversaciones/{id}',
        'Devuelve una conversacion del usuario con sus mensajes', 1,
        '{"PARAM.ID": "VARCHAR"}'::jsonb),
       ('PUT', '/ai/agente/conversaciones/{id}/archivar',
        'Archiva una conversacion del usuario (no la borra)', 1,
        '{"PARAM.ID": "VARCHAR"}'::jsonb),
       ('POST', '/ai/agente/conversaciones/{id}/mensajes',
        'Envia un mensaje del usuario y devuelve la respuesta del agente', 3,
        '{"PARAM.ID": "VARCHAR", "BODY.TEXTO": "VARCHAR", "BODY.CONTEXTO_UI": "JSONB"}'::jsonb),
       ('POST', '/ai/agente/conversaciones/{id}/mensajes/stream',
        'Mismo turno que /mensajes por Server-Sent Events: estados mientras avanza y la respuesta al final', 3,
        '{"PARAM.ID": "VARCHAR", "BODY.TEXTO": "VARCHAR", "BODY.CONTEXTO_UI": "JSONB"}'::jsonb),
       ('POST', '/ai/agente/acciones/{id}/confirmar',
        'Confirma una accion pendiente de escritura y la ejecuta con el token del usuario', 1,
        '{"PARAM.ID": "VARCHAR"}'::jsonb),
       ('POST', '/ai/agente/acciones/{id}/cancelar',
        'Descarta una accion pendiente de escritura', 1,
        '{"PARAM.ID": "VARCHAR"}'::jsonb);

INSERT INTO public.endpoint_microservice (endpoint_id, microservice_id)
SELECT e.id_endpoint, m.id_microservice
  FROM public.endpoint e
  JOIN public.microservice m ON m.serviceid = 'ai-control-service'
 WHERE e.path LIKE '/ai/agente/%'
ON CONFLICT DO NOTHING;

-- Roles: CEVAL-<codigo> de cada TROL con menu activo. Mismo criterio que fn_list_my_menus.
-- El catalogo TROL llega por el dump: en una base limpia (CI) no hay roles y solo se avisa.
DO $$
DECLARE
    v_roles INTEGER;
BEGIN
    SELECT COUNT(DISTINCT pr.id_role) INTO v_roles
      FROM public.role pr
      JOIN academico_test.trol t ON pr.name = 'CEVAL-' || t.codigo
      JOIN academico_test.trol_menu tm ON tm.fk_trol = t.pk_trol AND tm.active = TRUE
     WHERE t.active = TRUE AND t.estado = 'A';
    IF v_roles = 0 THEN
        RAISE NOTICE 'Ningun rol CEVAL-* con menu activo: /ai/agente queda sin roles';
    END IF;
END $$;

INSERT INTO public.role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
  FROM public.endpoint e
 CROSS JOIN (
     SELECT DISTINCT pr.id_role
       FROM public.role pr
       JOIN academico_test.trol t ON pr.name = 'CEVAL-' || t.codigo
       JOIN academico_test.trol_menu tm ON tm.fk_trol = t.pk_trol AND tm.active = TRUE
      WHERE t.active = TRUE AND t.estado = 'A'
 ) r
 WHERE e.path LIKE '/ai/agente/%'
ON CONFLICT DO NOTHING;
