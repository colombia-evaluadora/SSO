-- ===========================================================================
-- V151 - fn_sync_app_users: sincroniza public.app_users segun role_app, y backfill.
-- fn_sincronizar_rol_publico vive en V302.
-- ===========================================================================


CREATE OR REPLACE FUNCTION public.fn_sync_app_users(p_user_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_user_id IS NULL THEN
        RETURN;
    END IF;

    -- Agregar los apps que ahora corresponden (algún rol actual con
    -- role_app hacia ese app) y todavía no están en el roster.
    INSERT INTO public.app_users (id_app, id_user)
    SELECT DISTINCT ra.id_app, p_user_id
      FROM public.role_users ru
      JOIN public.role_app ra ON ra.id_role = ru.role_id
     WHERE ru.user_id = p_user_id
    ON CONFLICT DO NOTHING;

    -- Quitar los apps que ya no corresponden a ningún rol actual.
    DELETE FROM public.app_users au
     WHERE au.id_user = p_user_id
       AND NOT EXISTS (
            SELECT 1
              FROM public.role_users ru
              JOIN public.role_app ra ON ra.id_role = ru.role_id
             WHERE ru.user_id = p_user_id AND ra.id_app = au.id_app
           );
END;
$$;

COMMENT ON FUNCTION public.fn_sync_app_users(BIGINT) IS
    'Recalcula app_users de un usuario a partir de sus role_users x role_app actuales -- full-resync, no incremental. Llamada desde fn_sincronizar_rol_publico (academico_test) y desde UserAdminService.bindUserRole/unbindUserRole (sso-admin).';

INSERT INTO public.app_users (id_app, id_user)
SELECT DISTINCT ra.id_app, ru.user_id
  FROM public.role_users ru
  JOIN public.role_app ra ON ra.id_role = ru.role_id
 WHERE NOT EXISTS (
        SELECT 1 FROM public.app_users au
         WHERE au.id_app = ra.id_app AND au.id_user = ru.user_id
       );
