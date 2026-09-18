-- ===========================================================================
-- V260 — que roles puede otorgar cada rol, y el endpoint que lo usa.
--
-- Hasta ahora el alta de cuentas era todo-o-nada: quien alcanzaba
-- POST /register/usuario podia pedir cualquier rol. Para delegar el alta en
-- el administrador de una app (PIGSE-ADMINISTRADOR) hace falta acotar que
-- roles puede repartir, o la delegacion es una escalada de privilegios.
--
-- POR QUE UNA TABLA Y NO UN PESO NUMERICO EN public.role. Los roles cruzan
-- apps (CEVAL-*, PIGSE-*, ADMIN): un entero global que ordene
-- 'CEVAL-RECTOR' contra 'PIGSE-JEFE_AREA_CALIDAD' no significa nada. La
-- relacion explicita se lee, se audita y se edita por fila.
-- ===========================================================================

CREATE TABLE IF NOT EXISTS public.role_grant (
    granting_role_id  BIGINT NOT NULL REFERENCES public.role(id_role) ON DELETE CASCADE,
    grantable_role_id BIGINT NOT NULL REFERENCES public.role(id_role) ON DELETE CASCADE,
    PRIMARY KEY (granting_role_id, grantable_role_id)
);

CREATE INDEX IF NOT EXISTS idx_role_grant_granting ON public.role_grant (granting_role_id);

COMMENT ON TABLE public.role_grant IS
    'Que roles puede otorgar cada rol al dar de alta una cuenta. ADMIN no '
    'aparece aqui: tiene bypass en AccountRegistrationService.';

-- PIGSE-ADMINISTRADOR reparte todos los roles de su app menos el suyo:
-- no puede clonarse a si mismo. La consulta se resuelve por role_app, asi
-- que un rol PIGSE nuevo entra solo con volver a correr este INSERT.
INSERT INTO public.role_grant (granting_role_id, grantable_role_id)
SELECT admin.id_role, r.id_role
  FROM public.role admin
  JOIN public.role_app ra ON ra.id_role = admin.id_role
  JOIN public.app a       ON a.id_app   = ra.id_app AND a.name = 'PIGSE'
  JOIN public.role_app ra2 ON ra2.id_app = a.id_app
  JOIN public.role r       ON r.id_role  = ra2.id_role
 WHERE admin.name = 'PIGSE-ADMINISTRADOR'
   AND r.name <> 'PIGSE-ADMINISTRADOR'
   AND NOT EXISTS (
       SELECT 1 FROM public.role_grant rg
        WHERE rg.granting_role_id = admin.id_role
          AND rg.grantable_role_id = r.id_role
   );

INSERT INTO public.endpoint (method, path, description, numberparams, param_types)
SELECT 'POST', '/register/account', 'Alta de cuenta SSO con rol y contrasena por defecto', 0, '{}'::jsonb
 WHERE NOT EXISTS (
     SELECT 1 FROM public.endpoint
      WHERE path = '/register/account' AND method = 'POST'
        AND description = 'Alta de cuenta SSO con rol y contrasena por defecto'
 );

INSERT INTO public.role_endpoint (role_id, endpoint_id)
SELECT r.id_role, e.id_endpoint
  FROM public.endpoint e
  JOIN public.role r ON r.name IN ('ADMIN', 'PIGSE-ADMINISTRADOR')
 WHERE e.path = '/register/account' AND e.method = 'POST'
   AND NOT EXISTS (
       SELECT 1 FROM public.role_endpoint re
        WHERE re.endpoint_id = e.id_endpoint AND re.role_id = r.id_role
   );
