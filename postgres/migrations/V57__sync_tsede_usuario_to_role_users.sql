-- ===========================================================================
-- V57 — Trigger que sincroniza academico_test.tsede_usuario con public.role_users.
--
-- Cobertura:
--   * Disparador AFTER INSERT sobre academico_test.tsede_usuario.
--   * Para cada fila nueva, resuelve el codigo del rol desde trol, construye
--     el nombre `CEVAL-<codigo>` (mismo formato que V36 importa desde
--     academico_test.TROL a public.role), y agrega ese rol al usuario SSO
--     correspondiente en public.role_users.
--
-- Mapping:
--   tsede_usuario.fk_trol     ->  trol.codigo                       ->  public.role.name = 'CEVAL-' || codigo
--   tsede_usuario.fk_tusuario ->  tusuario.cuenta  ==  users.email   ->  public.users.id_user
--
-- Idempotencia:
--   * CREATE OR REPLACE FUNCTION + DROP TRIGGER IF EXISTS antes del CREATE.
--   * Auto-crea el rol en public.role si no existe (descripcion = trol.nombre).
--   * role_users se inserta con ON CONFLICT DO NOTHING sobre la PK (user_id, role_id).
--
-- No-op defensivo (WARNING, no error) si:
--   * TROL no tiene codigo.
--   * tusuario no tiene fila en public.users (asimetría del modelo: SSO es
--     source-of-truth; si el academic user no está en SSO, no podemos asignarle
--     un rol aquí — debe resolverse vía /register/* que crea ambas filas).
--
-- No cubre (fuera de scope):
--   * UPDATE de tsede_usuario (no cambia el rol en SSO — decisión consciente
--     para evitar inconsistencias con el flujo manual de sso-admin).
--   * DELETE de tsede_usuario (no remueve el rol en SSO — mismo motivo).
-- ===========================================================================

SET search_path TO academico_test, public;


-- ---------------------------------------------------------------------------
-- fn_sync_tsede_usuario_to_role_users
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_sync_tsede_usuario_to_role_users()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_codigo     VARCHAR;
    v_role_name  VARCHAR;
    v_user_id    BIGINT;
    v_role_id    BIGINT;
BEGIN
    -- 1. Resolver el codigo del rol desde TROL.
    SELECT codigo
      INTO v_codigo
      FROM academico_test.trol
     WHERE pk_trol = NEW.fk_trol;

    IF v_codigo IS NULL OR LENGTH(TRIM(v_codigo)) = 0 THEN
        RAISE WARNING 'fn_sync_tsede_usuario_to_role_users: TROL pk=% sin codigo — skip',
            NEW.fk_trol;
        RETURN NEW;
    END IF;

    -- 2. Construir el nombre del rol con el formato CEVAL-<codigo>.
    v_role_name := 'CEVAL-' || v_codigo;

    -- 3. Resolver el SSO user_id via tusuario.cuenta == users.email.
    --    Asimetría: si no hay fila en public.users, no podemos asignarle
    --    el rol; WARNING + skip (no raise, para no romper el flujo academico).
    SELECT u.id_user
      INTO v_user_id
      FROM public.users u
      JOIN academico_test.tusuario t
        ON UPPER(t.cuenta) = UPPER(u.email)
     WHERE t.pk_tusuario = NEW.fk_tusuario
       AND t.active = TRUE
     LIMIT 1;

    IF v_user_id IS NULL THEN
        RAISE WARNING 'fn_sync_tsede_usuario_to_role_users: tusuario pk=% sin fila en public.users — skip',
            NEW.fk_tusuario;
        RETURN NEW;
    END IF;

    -- 4. Auto-crear el rol en public.role si no existe. La descripcion
    --    viene de trol.nombre (etiqueta humana del rol academico).
    INSERT INTO public.role (name, description)
    SELECT v_role_name, t.nombre
      FROM academico_test.trol t
     WHERE t.pk_trol = NEW.fk_trol
    ON CONFLICT (name) DO NOTHING;

    -- 5. Resolver el id_role del rol (recien creado o preexistente).
    SELECT id_role
      INTO v_role_id
      FROM public.role
     WHERE name = v_role_name;

    IF v_role_id IS NULL THEN
        RAISE WARNING 'fn_sync_tsede_usuario_to_role_users: rol % no encontrado tras auto-crear — skip',
            v_role_name;
        RETURN NEW;
    END IF;

    -- 6. Vincular el usuario SSO con el rol en public.role_users.
    --    ON CONFLICT sobre la PK compuesta (user_id, role_id) hace la
    --    operacion idempotente.
    INSERT INTO public.role_users (user_id, role_id)
    VALUES (v_user_id, v_role_id)
    ON CONFLICT (user_id, role_id) DO NOTHING;

    RETURN NEW;
END;
$$;


DROP TRIGGER IF EXISTS trg_sync_tsede_usuario_to_role_users
    ON academico_test.tsede_usuario;

CREATE TRIGGER trg_sync_tsede_usuario_to_role_users
    AFTER INSERT ON academico_test.tsede_usuario
    FOR EACH ROW
    EXECUTE FUNCTION academico_test.fn_sync_tsede_usuario_to_role_users();


COMMENT ON FUNCTION academico_test.fn_sync_tsede_usuario_to_role_users()
    IS 'Trigger AFTER INSERT ON tsede_usuario: agrega el rol CEVAL-<codigo> al usuario SSO correspondiente al tsede_usuario.fk_tusuario. Mapping: tsede_usuario.fk_trol -> trol.codigo -> public.role.name; tsede_usuario.fk_tusuario -> tusuario.cuenta -> users.email -> users.id_user. Auto-crea el rol en public.role (descripcion = trol.nombre) si no existe. Idempotente via ON CONFLICT DO NOTHING. No-op si TROL sin codigo o si tusuario no tiene fila en public.users (asimetría del modelo SSO source-of-truth).';
