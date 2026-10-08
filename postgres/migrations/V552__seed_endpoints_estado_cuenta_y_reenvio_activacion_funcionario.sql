-- ===========================================================================
-- V552 - registra en el catalogo los endpoints de auth-center
--          POST /register/{cval,pigse}/funcionario/estado-cuenta
--          POST /register/{cval,pigse}/funcionario/reenviar-activacion
--        SOLO DATOS (endpoint, role_endpoint, endpoint_microservice): no
--        cambia el esquema ni toca role_app.
--
-- QUE HACEN
--   Desde la tabla de funcionarios (CE / PIGSE) el rector/admin ve si la
--   cuenta de cada funcionario esta pendiente de activacion y, SOLO en ese
--   caso, reenvia el correo account-activation. auth-center delega por
--   /internal/** en sso-admin (UserAdminService), igual que V550.
--
-- POR QUE UNA MIGRACION NUEVA
--   Los endpoints son nuevos: ninguna migracion previa posee sus filas.
--
-- AUTORIZACION
--   Gate role_endpoint de AuthCenterAccessManager. Cada endpoint hereda
--   EXACTAMENTE los roles de reactivar-por-cambio-de-correo de su app (V550,
--   que a su vez copio los del alta de funcionarios); se copian de
--   role_endpoint, no se listan a mano.
-- ===========================================================================

INSERT INTO public.endpoint (method, path, description, numberparams)
VALUES ('POST', '/register/cval/funcionario/estado-cuenta',
        'Estado de cuenta (activacion) de funcionarios CE', 0),
       ('POST', '/register/pigse/funcionario/estado-cuenta',
        'Estado de cuenta (activacion) de funcionarios PIGSE', 0),
       ('POST', '/register/cval/funcionario/reenviar-activacion',
        'Reenviar activacion a un funcionario CE pendiente', 0),
       ('POST', '/register/pigse/funcionario/reenviar-activacion',
        'Reenviar activacion a un funcionario PIGSE pendiente', 0)
ON CONFLICT (path, method, description) DO NOTHING;

INSERT INTO public.role_endpoint (endpoint_id, role_id)
SELECT nuevo.id_endpoint, re.role_id
  FROM (VALUES ('/register/cval/funcionario/reactivar-por-cambio-de-correo',
                '/register/cval/funcionario/estado-cuenta'),
               ('/register/cval/funcionario/reactivar-por-cambio-de-correo',
                '/register/cval/funcionario/reenviar-activacion'),
               ('/register/pigse/funcionario/reactivar-por-cambio-de-correo',
                '/register/pigse/funcionario/estado-cuenta'),
               ('/register/pigse/funcionario/reactivar-por-cambio-de-correo',
                '/register/pigse/funcionario/reenviar-activacion')) AS par(origen, destino)
  JOIN public.endpoint origen ON origen.method = 'POST' AND origen.path = par.origen
  JOIN public.role_endpoint re ON re.endpoint_id = origen.id_endpoint
  JOIN public.endpoint nuevo  ON nuevo.method = 'POST' AND nuevo.path = par.destino
ON CONFLICT (endpoint_id, role_id) DO NOTHING;

INSERT INTO public.endpoint_microservice (endpoint_id, microservice_id)
SELECT e.id_endpoint, m.id_microservice
  FROM public.endpoint e
  JOIN public.microservice m ON m.serviceid = 'auth-center'
 WHERE e.method = 'POST'
   AND e.path IN ('/register/cval/funcionario/estado-cuenta',
                  '/register/pigse/funcionario/estado-cuenta',
                  '/register/cval/funcionario/reenviar-activacion',
                  '/register/pigse/funcionario/reenviar-activacion')
   AND NOT EXISTS (
       SELECT 1 FROM public.endpoint_microservice em
        WHERE em.endpoint_id = e.id_endpoint AND em.microservice_id = m.id_microservice
   );
