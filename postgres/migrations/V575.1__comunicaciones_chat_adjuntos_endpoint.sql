-- V575.1 -- Chat: subir adjuntos por file-service (catalogo de endpoints y permiso)
-- Que hace: registra la subida multipart POST /files/eval-col/comunicaciones/
--   conversaciones/*/mensajes y su destino POST /eval-col/comunicaciones/
--   conversaciones/*/mensajes, y concede la subida a todo rol CEVAL-*.
-- Por que: file-service solo sube si el rol tiene un binding role_endpoint que
--   matchee la ruta entrante (puedeSubir) y si el destino existe en `endpoint`
--   o `query` (resolverDestino). El chat lo usan todos los perfiles (V562) y la
--   membresia del canal la valida comms-service al recibir el mensaje; el
--   generico POST /files/** queda solo para los roles que ya lo tenian.
-- Sin endpoint_microservice en el destino: file-service lo reenvia tal cual a
--   <gateway>/api/eval-col/comunicaciones/..., que el gateway manda a comms-service.
-- Idempotente: ON CONFLICT DO NOTHING en las tres tablas.

INSERT INTO public.endpoint (method, path, description, numberparams)
VALUES ('POST', '/files/eval-col/comunicaciones/conversaciones/*/mensajes',
        'Chat: mensaje con adjunto (multipart, campo ADJUNTO) via file-service', 0),
       ('POST', '/eval-col/comunicaciones/conversaciones/*/mensajes',
        'Chat: destino del reenvio de file-service (comms-service)', 0)
ON CONFLICT (path, method, description) DO NOTHING;

INSERT INTO public.endpoint_microservice (endpoint_id, microservice_id)
SELECT e.id_endpoint, m.id_microservice
  FROM public.endpoint e, public.microservice m
 WHERE (e.method, e.path) = ('POST', '/files/eval-col/comunicaciones/conversaciones/*/mensajes')
   AND m.serviceid = 'file-service'
ON CONFLICT DO NOTHING;

INSERT INTO public.role_endpoint (endpoint_id, role_id)
SELECT e.id_endpoint, r.id_role
  FROM public.endpoint e, public.role r
 WHERE (e.method, e.path) = ('POST', '/files/eval-col/comunicaciones/conversaciones/*/mensajes')
   AND r.name LIKE 'CEVAL-%'
ON CONFLICT DO NOTHING;
