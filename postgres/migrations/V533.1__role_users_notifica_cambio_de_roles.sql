-- ===========================================================================
-- V533.1 - public.role_users: avisar a auth-center cuando cambian los roles
--          de un usuario, para que borre su set cacheado en Redis.
--
-- auth-center cachea los roles efectivos por email (1 h) y con ellos firma
-- el claim "roles" del JWT. Solo sso-admin invalidaba esa cache: quitar un
-- permiso por query-service (fn_fun_permisos_actualizar -> resync V301)
-- dejaba el rol revocado en cada login durante la hora siguiente.
-- El aviso sale por pg_notify, que solo se entrega al hacer COMMIT.
-- Depende de: V1 (role_users, users). Escucha: RoleChangeListener.
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.fn_trg_role_users_notificar_cambio()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_email TEXT;
BEGIN
    -- Las tablas de transicion solo existen segun la operacion, y una consulta
    -- que nombre la ausente falla al planificarse: una rama por tabla.
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        FOR v_email IN
            SELECT DISTINCT u.email
              FROM public.users u
              JOIN role_users_cambio c ON c.user_id = u.id_user
        LOOP
            PERFORM pg_notify('sso_user_roles_changed', v_email);
        END LOOP;
    END IF;

    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        FOR v_email IN
            SELECT DISTINCT u.email
              FROM public.users u
              JOIN role_users_previo p ON p.user_id = u.id_user
        LOOP
            PERFORM pg_notify('sso_user_roles_changed', v_email);
        END LOOP;
    END IF;

    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_role_users_notificar_ins ON public.role_users;
CREATE TRIGGER trg_role_users_notificar_ins
    AFTER INSERT ON public.role_users
    REFERENCING NEW TABLE AS role_users_cambio
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.fn_trg_role_users_notificar_cambio();

DROP TRIGGER IF EXISTS trg_role_users_notificar_upd ON public.role_users;
CREATE TRIGGER trg_role_users_notificar_upd
    AFTER UPDATE ON public.role_users
    REFERENCING NEW TABLE AS role_users_cambio OLD TABLE AS role_users_previo
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.fn_trg_role_users_notificar_cambio();

DROP TRIGGER IF EXISTS trg_role_users_notificar_del ON public.role_users;
CREATE TRIGGER trg_role_users_notificar_del
    AFTER DELETE ON public.role_users
    REFERENCING OLD TABLE AS role_users_previo
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.fn_trg_role_users_notificar_cambio();

COMMENT ON FUNCTION public.fn_trg_role_users_notificar_cambio() IS
    'INTERNO: trigger por sentencia sobre public.role_users. Emite pg_notify(''sso_user_roles_changed'', email) por cada usuario cuyos roles cambiaron; auth-center (RoleChangeListener) borra su set cacheado en Redis. Postgres colapsa avisos repetidos de una misma transaccion y solo los entrega al COMMIT.';
