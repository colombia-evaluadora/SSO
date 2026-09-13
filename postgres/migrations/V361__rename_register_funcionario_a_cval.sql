-- V361 — /register/funcionario (auth-center, escribe en academico_test.*,
-- lo usa el front de Colombia Evaluadora) no tenía marca de app en la ruta,
-- a diferencia de /register/pigse/funcionario (V360) y de auditoría
-- (/audit-cval vs /audit-pigse, V356/V357). Asimetría confusa: cualquiera
-- que mire la lista de endpoints ve un "genérico" y un "pigse", cuando en
-- realidad ambos son específicos de una app. Se renombra a
-- /register/cval/funcionario para quedar simétrico con el resto del
-- dominio.
--
-- El controller (AuthController.java) y su SecurityConfig ya se movieron a
-- @PostMapping("/register/cval/funcionario") / .requestMatchers(...,
-- "/register/cval/funcionario") en este mismo commit. Esta migración solo
-- tiene que poner la fila de public.endpoint al día: es un UPDATE del path,
-- no un INSERT nuevo + borrar el viejo, porque role_endpoint y
-- endpoint_microservice cuelgan de endpoint_id (FK), no del path — todos
-- los roles que ya podían pegarle a /register/funcionario (CEVAL-*,
-- SSO-ADMIN, ADMIN) siguen intactos sin volver a listarlos.
--
-- file-service (FileDestinationAccessService) resuelve el destino de los
-- multipart leyendo public.endpoint en vivo (SELECT ... FROM endpoint),
-- así que no hace falta tocar nada ahí: en cuanto esta fila cambia de path,
-- /files/register/cval/funcionario empieza a resolver solo.
UPDATE public.endpoint
   SET path = '/register/cval/funcionario'
 WHERE method = 'POST'
   AND path = '/register/funcionario';

-- Verificación: la fila vieja ya no existe, la nueva sí, y los binds de
-- role_endpoint / endpoint_microservice se conservaron (mismo endpoint_id).
DO $$
DECLARE
    v_id_endpoint BIGINT;
    v_role_binds INTEGER;
    v_microservice_binds INTEGER;
BEGIN
    IF EXISTS (SELECT 1 FROM public.endpoint WHERE method = 'POST' AND path = '/register/funcionario') THEN
        RAISE EXCEPTION 'V361: /register/funcionario todavia existe en public.endpoint';
    END IF;

    SELECT id_endpoint INTO v_id_endpoint
      FROM public.endpoint
     WHERE method = 'POST' AND path = '/register/cval/funcionario';

    IF v_id_endpoint IS NULL THEN
        RAISE EXCEPTION 'V361: /register/cval/funcionario no quedo registrado en public.endpoint';
    END IF;

    SELECT count(*) INTO v_role_binds
      FROM public.role_endpoint
     WHERE endpoint_id = v_id_endpoint;
    IF v_role_binds = 0 THEN
        RAISE EXCEPTION 'V361: /register/cval/funcionario quedo sin role_endpoint';
    END IF;

    SELECT count(*) INTO v_microservice_binds
      FROM public.endpoint_microservice
     WHERE endpoint_id = v_id_endpoint;
    IF v_microservice_binds = 0 THEN
        RAISE EXCEPTION 'V361: /register/cval/funcionario quedo sin endpoint_microservice';
    END IF;
END $$;
