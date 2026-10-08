-- ===========================================================================
-- V549 - registra en el catalogo los endpoints de auth-center
--          POST /register/cval/funcionario/reactivar-por-cambio-de-correo
--          POST /register/pigse/funcionario/reactivar-por-cambio-de-correo
--        SOLO DATOS (endpoint, role_endpoint, endpoint_microservice): no
--        cambia el esquema ni toca role_app.
--
-- QUE HACEN
--   Cuando un front (CE o PIGSE) cambia el correo de un funcionario, la
--   sincronizacion SQL (V215) actualiza public.users pero no puede mandar
--   correos. El front llama a este endpoint despues de guardar: auth-center
--   delega por /internal/** en sso-admin, que deja la cuenta en
--   PENDING_ACTIVATION, rota el token de activacion, invalida las sesiones y
--   envia account-activation al correo nuevo.
--
-- POR QUE UNA MIGRACION NUEVA
--   Los endpoints son nuevos: ninguna migracion previa posee sus filas.
--
-- AUTORIZACION
--   Gate role_endpoint de AuthCenterAccessManager (sin role_app: auth-center
--   no lo exige). Cada endpoint hereda EXACTAMENTE los roles que hoy pueden
--   registrar funcionarios en su app (se copian de role_endpoint, no se listan
--   a mano), asi el permiso queda alineado con el alta.
-- ===========================================================================

INSERT INTO public.endpoint (method, path, description, numberparams)
VALUES ('POST', '/register/cval/funcionario/reactivar-por-cambio-de-correo',
        'Reenviar activacion al correo nuevo de un funcionario CE', 0),
       ('POST', '/register/pigse/funcionario/reactivar-por-cambio-de-correo',
        'Reenviar activacion al correo nuevo de un funcionario PIGSE', 0)
ON CONFLICT (path, method, description) DO NOTHING;

INSERT INTO public.role_endpoint (endpoint_id, role_id)
SELECT nuevo.id_endpoint, re.role_id
  FROM (VALUES ('/register/cval/funcionario',
                '/register/cval/funcionario/reactivar-por-cambio-de-correo'),
               ('/register/pigse/funcionario',
                '/register/pigse/funcionario/reactivar-por-cambio-de-correo')) AS par(origen, destino)
  JOIN public.endpoint alta  ON alta.method = 'POST'  AND alta.path = par.origen
  JOIN public.role_endpoint re ON re.endpoint_id = alta.id_endpoint
  JOIN public.endpoint nuevo ON nuevo.method = 'POST' AND nuevo.path = par.destino
ON CONFLICT (endpoint_id, role_id) DO NOTHING;

INSERT INTO public.endpoint_microservice (endpoint_id, microservice_id)
SELECT e.id_endpoint, m.id_microservice
  FROM public.endpoint e
  JOIN public.microservice m ON m.serviceid = 'auth-center'
 WHERE e.method = 'POST'
   AND e.path IN ('/register/cval/funcionario/reactivar-por-cambio-de-correo',
                  '/register/pigse/funcionario/reactivar-por-cambio-de-correo')
   AND NOT EXISTS (
       SELECT 1 FROM public.endpoint_microservice em
        WHERE em.endpoint_id = e.id_endpoint AND em.microservice_id = m.id_microservice
   );
