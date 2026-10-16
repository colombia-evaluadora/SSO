-- V587 -- Foros: subir adjuntos por file-service (catalogo de endpoints y permiso)
-- Que hace: registra las subidas multipart
--     POST /files/eval-col/comunicaciones/foros/*/publicaciones
--     POST /files/eval-col/comunicaciones/foros/publicaciones/*/respuestas
--   y sus destinos en comms-service, y concede la subida a todo rol CEVAL-*.
-- Por que: igual que el chat (V575.1). file-service solo sube si el rol tiene un
--   role_endpoint que matchee la ruta entrante (puedeSubir) y si el destino existe
--   en `endpoint` (resolverDestino). Quien publica o responde en un foro lo decide
--   comms-service (membresia del canal FORO y politica de foros) al recibir el
--   reenvio con ADJUNTO = pk_tarchivo; ver comms ForoService/AdjuntosChat.
-- Sin tablas ni columnas nuevas: el cuerpo y las respuestas de un foro son filas de
--   comunicaciones.tmensaje (V585), que ya tiene fk_tarchivo/adjunto_peso (V560).
-- Idempotente: ON CONFLICT DO NOTHING en las tres tablas.

INSERT INTO public.endpoint (method, path, description, numberparams)
VALUES ('POST', '/files/eval-col/comunicaciones/foros/*/publicaciones',
        'Foros: publicacion con adjunto (multipart, campo ADJUNTO) via file-service', 0),
       ('POST', '/eval-col/comunicaciones/foros/*/publicaciones',
        'Foros: destino del reenvio de file-service (comms-service)', 0),
       ('POST', '/files/eval-col/comunicaciones/foros/publicaciones/*/respuestas',
        'Foros: respuesta con adjunto (multipart, campo ADJUNTO) via file-service', 0),
       ('POST', '/eval-col/comunicaciones/foros/publicaciones/*/respuestas',
        'Foros: destino del reenvio de file-service (comms-service)', 0)
ON CONFLICT (path, method, description) DO NOTHING;

INSERT INTO public.endpoint_microservice (endpoint_id, microservice_id)
SELECT e.id_endpoint, m.id_microservice
  FROM public.endpoint e, public.microservice m
 WHERE e.method = 'POST'
   AND e.path IN ('/files/eval-col/comunicaciones/foros/*/publicaciones',
                  '/files/eval-col/comunicaciones/foros/publicaciones/*/respuestas')
   AND m.serviceid = 'file-service'
ON CONFLICT DO NOTHING;

INSERT INTO public.role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
  FROM public.endpoint e, public.role r
 WHERE e.method = 'POST'
   AND e.path IN ('/files/eval-col/comunicaciones/foros/*/publicaciones',
                  '/files/eval-col/comunicaciones/foros/publicaciones/*/respuestas')
   AND r.name LIKE 'CEVAL-%'
ON CONFLICT DO NOTHING;
