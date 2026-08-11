-- ===========================================================================
-- V54 — Sync users.password -> academico_test.tusuario.contrasena.
--
-- Trigger AFTER UPDATE OF password sobre public.users que propaga el hash
-- al TUSUARIO activo cuyo CORREO_ELECTRONICO coincide (case-insensitive).
--
-- Dependencias:
--   * V1   (sso-identity): tabla public.users.
--   * V22  (academic-schema): tabla academico_test.tusuario.
--
-- Idempotencia:
--   * CREATE OR REPLACE FUNCTION + DROP TRIGGER IF EXISTS.
-- ===========================================================================

SET search_path TO academico_test, public;


CREATE OR REPLACE FUNCTION academico_test.fn_sync_users_password_to_tusuario()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_rows BIGINT;
BEGIN
    IF NEW.password IS NULL THEN RETURN NEW; END IF;
    UPDATE academico_test.tusuario t
       SET contrasena = NEW.password,
           modified_by = COALESCE(NEW.id_user::VARCHAR, t.modified_by),
           modified_at = CURRENT_TIMESTAMP
     WHERE UPPER(t.cuenta) = UPPER(NEW.email)
       AND t.active = TRUE;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows > 1 THEN
        RAISE WARNING 'fn_sync_users_password_to_tusuario: % filas actualizadas para email=%',
            v_rows, NEW.email;
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_sync_users_password ON users;
CREATE TRIGGER trg_sync_users_password
    AFTER UPDATE OF password ON users
    FOR EACH ROW
    WHEN (OLD.password IS DISTINCT FROM NEW.password)
    EXECUTE FUNCTION academico_test.fn_sync_users_password_to_tusuario();
