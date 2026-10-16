-- V557.3 -- Endpoints del agente en el catalogo: /ai/agente/** (ai-control-service)
-- Que hace: registra 10 endpoints en public.endpoint, su microservicio y sus roles, y el menu ASISTENTE.
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
                          ('POST',   '/ai/agente/acciones/{id}/cancelar'),
                          ('POST',   '/ai/agente/conversaciones/{id}/cancelar'),
                          ('GET',    '/ai/agente/sugerencias'));

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
       ('POST', '/ai/agente/conversaciones/{id}/cancelar',
        'Corta el turno en curso de una conversacion del usuario y libera su turno', 1,
        '{"PARAM.ID": "VARCHAR"}'::jsonb),
       ('GET', '/ai/agente/sugerencias',
        'Sugerencias de mensajes para la pantalla abierta y resumen de capacidades, segun los menus del usuario', 1,
        '{"QUERY.RUTA": "VARCHAR"}'::jsonb),
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

-- Menu ASISTENTE: no navega (VISIBLE 'N', sin URL); el front lo lee con permisos-menu para
-- mostrar el asistente. Crear/editar = puede preparar escrituras; nunca elimina.
INSERT INTO academico_test.tmenu
    (codigo, fk_tmenu, nombre, url, icono, visible, orden, estado, admite_guardar, admite_eliminar,
     active, created_by, created_at)
SELECT 'ASISTENTE', NULL, 'Asistente', NULL, NULL, 'N', 99, 'A', TRUE, FALSE, TRUE, 'migracion', CURRENT_TIMESTAMP
 WHERE NOT EXISTS (SELECT 1 FROM academico_test.tmenu m WHERE m.codigo = 'ASISTENTE');

-- Mismos roles que el endpoint. NOT EXISTS sin mirar ACTIVE: no revive lo que se quito desde la UI.
INSERT INTO academico_test.trol_menu (fk_trol, fk_tmenu, active, created_by, created_at)
SELECT r.pk_trol, a.pk_tmenu, TRUE, 'migracion', CURRENT_TIMESTAMP
  FROM (SELECT DISTINCT t.pk_trol
          FROM academico_test.trol t
          JOIN academico_test.trol_menu tm ON tm.fk_trol = t.pk_trol AND tm.active = TRUE
         WHERE t.active = TRUE AND t.estado = 'A') r
 CROSS JOIN (SELECT pk_tmenu FROM academico_test.tmenu
              WHERE codigo = 'ASISTENTE' AND active = TRUE ORDER BY pk_tmenu LIMIT 1) a
 WHERE NOT EXISTS (SELECT 1 FROM academico_test.trol_menu x
                    WHERE x.fk_trol = r.pk_trol AND x.fk_tmenu = a.pk_tmenu);
