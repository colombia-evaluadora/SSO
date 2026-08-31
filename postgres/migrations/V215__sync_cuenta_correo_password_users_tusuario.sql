-- ===========================================================================
-- V215 — Sincronizacion bidireccional de la cuenta (correo) y la contrasena
--        entre public.users (identidad SSO) y academico_test.tusuario
--        (identidad academica).
--
-- Contexto (bug CU-86e30a25v).
--   El alta de funcionario/usuario/estudiante liga las dos caras del sistema.
--   Hasta hoy la unica sincronizacion viva era V54: public.users.password ->
--   tusuario.CONTRASENA. Todo lo demas quedaba desincronizado:
--     * "editar correo" del funcionario (fn_fun_actualizar, V51) solo tocaba
--       TUSUARIO.CORREO_ELECTRONICO -> CUENTA y public.users.email viejos.
--     * "editar correo" del usuario (sso-admin PUT /updateAccount) cambiaba
--       public.users.email -> TUSUARIO viejo, y el puente V48 devolvia NULL.
--       Ademas el trigger V54 buscaba CUENTA = NEW.email, asi que los
--       "olvide mi contrasena" posteriores eran no-op del lado academico.
--     * "cambiar contrasena" del funcionario/estudiante (fn_fun_actualizar /
--       fn_est_*) no volvia a public.users.password.
--
-- Modelo de emparejamiento (regla de negocio acordada).
--   * FUNCIONARIOS y ACUDIENTES: CUENTA = CORREO_ELECTRONICO = users.email.
--     La fila de public.users se ubica por CUENTA.
--   * ESTUDIANTES: CUENTA = tipo_documento + identificacion (NO es correo),
--     pero TAMBIEN tienen fila en public.users (creada por /register/usuario)
--     que se ubica por su CORREO_ELECTRONICO. Su CUENTA nunca se toca desde
--     este lado.
--   El discriminador es: tiene TESTUDIANTE activo, o (CUENTA != CORREO y la
--   unica fila de users que matchea es la de CORREO_ELECTRONICO).
--   Si NO existe fila en public.users, los triggers no hacen nada (no crean).
--
-- Que sincroniza.
--   users.password        <-> tusuario.CONTRASENA
--   users.email           <-> tusuario.CUENTA (funcionario/acudiente)
--   users.email           <-> tusuario.CORREO_ELECTRONICO (estudiante, y
--                              tambien funcionario cuando CORREO espejaba CUENTA)
--   Un cambio de tusuario.CORREO_ELECTRONICO en una cuenta de funcionario que
--   lo espejaba se trata como renombre de la cuenta (mueve CUENTA + users.email)
--   -> "editar correo" del funcionario funciona de punta a punta sin tocar V51.
--
-- Puente V48.
--   public.fn_get_academico_usuario_id gana un fallback por CORREO_ELECTRONICO
--   cuando el lookup por CUENTA no encuentra nada (caso estudiante).
--
-- Anti-recursion.
--   Guard pg_trigger_depth() > 1 en ambas funciones: el trigger que dispara la
--   propagacion corre a profundidad 1; los UPDATE hacia la otra tabla corren a
--   profundidad 2 y salen de inmediato. Sin ciclo.
--
-- Dependencias.
--   * V1  (sso-identity): public.users(email, password, id_user).
--   * V22 (academic-schema): academico_test.tusuario(cuenta, correo_electronico,
--          contrasena, active, modified_by, modified_at).
--   * V48: se reemplaza public.fn_get_academico_usuario_id (fallback por correo).
--   * V54: se reemplaza fn_sync_users_password_to_tusuario /
--          trg_sync_users_password por las versiones ampliadas de abajo.
--   * V160: academico_test.testudiante(fk_tusuario, active) para el discriminador.
--
-- Idempotencia.
--   CREATE OR REPLACE FUNCTION + DROP TRIGGER IF EXISTS + DROP FUNCTION IF EXISTS.
-- ===========================================================================

SET search_path TO academico_test, public;


-- ---------------------------------------------------------------------------
-- Puente V48 + fallback por CORREO_ELECTRONICO (estudiantes).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_get_academico_usuario_id(p_user_id BIGINT)
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
SET search_path = public, academico_test
AS $$
DECLARE
    v_email       VARCHAR(200);
    v_tusuario_pk BIGINT;
BEGIN
    SELECT email INTO v_email FROM public.users WHERE id_user = p_user_id;
    IF v_email IS NULL THEN
        RETURN NULL;
    END IF;

    -- 1. Funcionario / acudiente: CUENTA espeja el correo de login.
    SELECT PK_TUSUARIO INTO v_tusuario_pk
      FROM academico_test.TUSUARIO
     WHERE CUENTA = v_email
     ORDER BY PK_TUSUARIO
     LIMIT 1;

    -- 2. Estudiante: CUENTA es el documento; la identidad se resuelve por
    --    el correo de negocio.
    IF v_tusuario_pk IS NULL THEN
        SELECT PK_TUSUARIO INTO v_tusuario_pk
          FROM academico_test.TUSUARIO
         WHERE UPPER(CORREO_ELECTRONICO) = UPPER(v_email)
           AND ACTIVE = TRUE
         ORDER BY PK_TUSUARIO
         LIMIT 1;
    END IF;

    RETURN v_tusuario_pk;
END;
$$;

COMMENT ON FUNCTION public.fn_get_academico_usuario_id(BIGINT) IS
    'V215: Returns academico_test.TUSUARIO.PK_TUSUARIO for a public.users.id_user. Resuelve primero por CUENTA (funcionario/acudiente) y, si no hay, por CORREO_ELECTRONICO activo (estudiante, cuya CUENTA es el documento). NULL si no existe en ninguno.';


-- ---------------------------------------------------------------------------
-- Sentido public.users -> academico_test.tusuario  (amplia V54).
--   Match por CUENTA = OLD.email  O  CORREO_ELECTRONICO = OLD.email.
--   El renombre de CUENTA / CORREO_ELECTRONICO se decide por-fila con CASE:
--     - CUENTA se mueve solo si venia espejando el correo de login.
--     - CORREO_ELECTRONICO se mueve solo si venia espejando el correo de login
--       (funcionario) o si la fila matcheo por correo (estudiante).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_sync_users_to_tusuario()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_rows BIGINT;
BEGIN
    IF pg_trigger_depth() > 1 THEN
        RETURN NEW;
    END IF;

    UPDATE academico_test.tusuario t
       SET contrasena = CASE
                            WHEN NEW.password IS NOT NULL
                             AND NEW.password IS DISTINCT FROM OLD.password
                            THEN NEW.password
                            ELSE t.contrasena
                         END,
           cuenta = CASE
                       WHEN NEW.email IS DISTINCT FROM OLD.email
                        AND UPPER(t.cuenta) = UPPER(OLD.email)
                       THEN NEW.email
                       ELSE t.cuenta
                    END,
           correo_electronico = CASE
                       WHEN NEW.email IS DISTINCT FROM OLD.email
                        AND UPPER(t.correo_electronico) = UPPER(OLD.email)
                       THEN NEW.email
                       ELSE t.correo_electronico
                    END,
           modified_by = COALESCE(NEW.id_user::VARCHAR, t.modified_by),
           modified_at = CURRENT_TIMESTAMP
     WHERE t.active = TRUE
       AND ( UPPER(t.cuenta) = UPPER(OLD.email)
          OR UPPER(t.correo_electronico) = UPPER(OLD.email) );

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows > 1 THEN
        RAISE WARNING 'fn_sync_users_to_tusuario: % filas actualizadas para email=%',
            v_rows, OLD.email;
    END IF;
    RETURN NEW;
END $$;

COMMENT ON FUNCTION academico_test.fn_sync_users_to_tusuario() IS
    'V215: propaga public.users.password/email al academico_test.tusuario activo cuya CUENTA o CORREO_ELECTRONICO coincide con OLD.email. CUENTA/CORREO_ELECTRONICO se mueven solo si venian espejando el correo de login. Reemplaza a fn_sync_users_password_to_tusuario (V54). Guard pg_trigger_depth()>1.';

DROP TRIGGER IF EXISTS trg_sync_users_password    ON public.users;
DROP TRIGGER IF EXISTS trg_sync_users_to_tusuario ON public.users;
CREATE TRIGGER trg_sync_users_to_tusuario
    AFTER UPDATE OF password, email ON public.users
    FOR EACH ROW
    WHEN (OLD.password IS DISTINCT FROM NEW.password
          OR OLD.email IS DISTINCT FROM NEW.email)
    EXECUTE FUNCTION academico_test.fn_sync_users_to_tusuario();

DROP FUNCTION IF EXISTS academico_test.fn_sync_users_password_to_tusuario();


-- ---------------------------------------------------------------------------
-- Sentido academico_test.tusuario -> public.users  (nuevo).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_sync_tusuario_to_users()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_is_student  BOOLEAN;
    v_match_email VARCHAR;   -- email actual en public.users a ubicar
    v_new_email   VARCHAR;   -- email nuevo para public.users
BEGIN
    IF pg_trigger_depth() > 1 THEN
        RETURN NEW;
    END IF;

    -- Discriminador estudiante: tiene TESTUDIANTE activo, o su CUENTA no es el
    -- correo y la unica fila de users que lo matchea es la de CORREO_ELECTRONICO.
    v_is_student :=
        EXISTS (
            SELECT 1 FROM academico_test.testudiante e
             WHERE e.fk_tusuario = NEW.pk_tusuario AND e.active = TRUE
        )
        OR (
            UPPER(COALESCE(OLD.cuenta, '')) IS DISTINCT FROM UPPER(COALESCE(OLD.correo_electronico, ''))
            AND NOT EXISTS (SELECT 1 FROM public.users u WHERE UPPER(u.email) = UPPER(OLD.cuenta))
            AND EXISTS     (SELECT 1 FROM public.users u WHERE UPPER(u.email) = UPPER(OLD.correo_electronico))
        );

    IF v_is_student THEN
        -- Estudiante: la fila de users se ubica por el correo de negocio.
        -- CUENTA (documento) nunca se propaga.
        v_match_email := OLD.correo_electronico;
        IF v_match_email IS NULL THEN
            RETURN NEW;
        END IF;
        v_new_email := CASE
                          WHEN NEW.correo_electronico IS DISTINCT FROM OLD.correo_electronico
                          THEN NEW.correo_electronico
                          ELSE OLD.correo_electronico
                       END;
    ELSE
        -- Funcionario / acudiente: la fila de users se ubica por CUENTA.
        v_match_email := OLD.cuenta;
        IF NEW.cuenta IS DISTINCT FROM OLD.cuenta THEN
            v_new_email := NEW.cuenta;
        ELSIF NEW.correo_electronico IS DISTINCT FROM OLD.correo_electronico
              AND UPPER(OLD.cuenta) = UPPER(OLD.correo_electronico) THEN
            -- "editar correo" del funcionario via fn_fun_actualizar (solo toca
            -- CORREO_ELECTRONICO): se trata como renombre de la cuenta.
            v_new_email := NEW.correo_electronico;
            UPDATE academico_test.tusuario
               SET cuenta             = v_new_email,
                   correo_electronico = v_new_email
             WHERE pk_tusuario = NEW.pk_tusuario
               AND (cuenta IS DISTINCT FROM v_new_email
                    OR correo_electronico IS DISTINCT FROM v_new_email);
        ELSE
            v_new_email := OLD.cuenta;   -- solo cambio la contrasena
        END IF;
    END IF;

    UPDATE public.users
       SET email    = v_new_email,
           password = COALESCE(NEW.contrasena, password)
     WHERE UPPER(email) = UPPER(v_match_email)
       AND (email IS DISTINCT FROM v_new_email
            OR password IS DISTINCT FROM NEW.contrasena);

    RETURN NEW;
END $$;

COMMENT ON FUNCTION academico_test.fn_sync_tusuario_to_users() IS
    'V215: propaga cambios de CUENTA / CORREO_ELECTRONICO / CONTRASENA de academico_test.tusuario a public.users (email / password). Funcionario/acudiente: ubica users por CUENTA; un cambio de CORREO_ELECTRONICO que espejaba a CUENTA es renombre de cuenta. Estudiante (tiene TESTUDIANTE o CUENTA != correo con users solo por CORREO_ELECTRONICO): ubica users por CORREO_ELECTRONICO, la CUENTA (documento) nunca se propaga. No crea filas en users. Guard pg_trigger_depth()>1.';

DROP TRIGGER IF EXISTS trg_sync_tusuario_to_users ON academico_test.tusuario;
CREATE TRIGGER trg_sync_tusuario_to_users
    AFTER UPDATE OF cuenta, correo_electronico, contrasena ON academico_test.tusuario
    FOR EACH ROW
    WHEN (OLD.cuenta             IS DISTINCT FROM NEW.cuenta
          OR OLD.correo_electronico IS DISTINCT FROM NEW.correo_electronico
          OR OLD.contrasena       IS DISTINCT FROM NEW.contrasena)
    EXECUTE FUNCTION academico_test.fn_sync_tusuario_to_users();
