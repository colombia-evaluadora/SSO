-- ===========================================================================
-- V263 -- alta de usuarios que NO pertenecen a un establecimiento.
--
-- fn_fun_crear (V257) exige FK_TESTABLECIMIENTO, asi que los roles
-- territoriales (ADMINISTRADOR, SECRETARIA_TERRITORIAL, DIRECTOR_ENTE_*,
-- JEFE_*) no tenian forma de existir en pigse: la cuenta del SSO se creaba
-- pero sin fila en pigse.TUSUARIO, y como fn_usuario_tiene_rol resuelve el
-- permiso por TUSUARIO.FK_ID_USER, el usuario no podia operar.
--
-- Dos piezas: la operativa (fn_usuario_ente_crear, con gate) y la de arranque
-- (fn_usuario_provisionar, sin gate -- ver por que mas abajo).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Espeja en pigse la identidad de una cuenta del SSO que YA tiene un rol
-- PIGSE-*. Sin gate de rol a proposito: no otorga nada. La autoridad es
-- public.role_users, que solo escriben el ADMIN del SSO o quien tenga el rol
-- en public.role_grant (V260); esto solo copia nombre y correo para que el
-- permiso que el SSO ya concedio sea utilizable. Es lo que rompe el circulo
-- del primer PIGSE-ADMINISTRADOR.
--
-- Idempotente: si ya hay TUSUARIO activo para ese correo, lo devuelve.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pigse.fn_usuario_provisionar(p_email VARCHAR)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_id_user   BIGINT;
    v_full      VARCHAR;
    v_pk        BIGINT;
    v_nombre    VARCHAR;
    v_apellido  VARCHAR;
BEGIN
    IF NULLIF(TRIM(p_email), '') IS NULL THEN
        RAISE EXCEPTION 'Correo electronico es obligatorio' USING ERRCODE = '22023';
    END IF;

    SELECT u.PK_TUSUARIO INTO v_pk
      FROM pigse.TUSUARIO u
     WHERE LOWER(u.CORREO_ELECTRONICO) = LOWER(TRIM(p_email))
       AND u.ACTIVE = TRUE;
    IF v_pk IS NOT NULL THEN
        RETURN v_pk;
    END IF;

    SELECT us.id_user, us.full_name INTO v_id_user, v_full
      FROM public.users us
     WHERE LOWER(us.email) = LOWER(TRIM(p_email));

    IF v_id_user IS NULL THEN
        RAISE EXCEPTION 'No hay cuenta del SSO con el correo "%"', TRIM(p_email)
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.role_users ru
          JOIN public.role r ON r.id_role = ru.role_id
         WHERE ru.user_id = v_id_user AND r.name LIKE 'PIGSE-%'
    ) THEN
        RAISE EXCEPTION 'La cuenta "%" no tiene ningun rol PIGSE-* asignado', TRIM(p_email)
            USING ERRCODE = '42501';
    END IF;

    -- PRIMER_NOMBRE y PRIMER_APELLIDO son NOT NULL y el SSO solo guarda
    -- full_name: primera palabra al nombre, el resto al apellido. Se corrige
    -- despues con el PATCH del perfil; el correo es la identidad real.
    v_full     := COALESCE(NULLIF(TRIM(v_full), ''), TRIM(p_email));
    v_nombre   := SPLIT_PART(v_full, ' ', 1);
    v_apellido := NULLIF(TRIM(SUBSTRING(v_full FROM POSITION(' ' IN v_full) + 1)), '');
    IF v_apellido IS NULL OR v_apellido = v_nombre THEN
        v_apellido := '(sin apellido)';
    END IF;

    INSERT INTO pigse.TUSUARIO (
        FK_ID_USER, CORREO_ELECTRONICO, PRIMER_NOMBRE, PRIMER_APELLIDO,
        CREATED_BY, CREATED_AT, ACTIVE)
    VALUES (v_id_user, TRIM(p_email), v_nombre, LEFT(v_apellido, 40),
            'PROVISION_SSO', CURRENT_TIMESTAMP, TRUE)
    RETURNING PK_TUSUARIO INTO v_pk;

    RETURN v_pk;
END;
$$;

-- ---------------------------------------------------------------------------
-- Alta operativa: identidad en pigse + vinculo con un ente territorial.
-- Mismo gate y mismo estilo que fn_fun_crear (V257), pero sin establecimiento
-- y sin TFUNCIONARIO. El rol, si viene, se delega en fn_ente_usuario_crear,
-- que es quien sincroniza public.role_users.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pigse.fn_usuario_ente_crear(
    p_pk_usuario_solicitante BIGINT,
    p_fk_ente                BIGINT,
    p_correo_electronico     VARCHAR,
    p_identificacion         VARCHAR,
    p_primer_nombre          VARCHAR,
    p_primer_apellido        VARCHAR,
    p_segundo_nombre         VARCHAR DEFAULT NULL,
    p_segundo_apellido       VARCHAR DEFAULT NULL,
    p_telefono               VARCHAR DEFAULT NULL,
    p_fk_tlv_tipo_documento  BIGINT  DEFAULT NULL,
    p_fk_id_role             BIGINT  DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pigse, academico_test, public
AS $$
DECLARE
    v_pk_usuario BIGINT;
    v_id_user    BIGINT;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT pigse.fn_usuario_tiene_rol(p_pk_usuario_solicitante,
            ARRAY['PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL']::VARCHAR[]) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF NULLIF(TRIM(p_correo_electronico), '') IS NULL THEN
        RAISE EXCEPTION 'Correo electronico es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_identificacion), '') IS NULL THEN
        RAISE EXCEPTION 'Numero de identificacion es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_primer_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Primer nombre es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_primer_apellido), '') IS NULL THEN
        RAISE EXCEPTION 'Primer apellido es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_ente IS NULL THEN
        RAISE EXCEPTION 'Ente territorial (FK_TENTE) es obligatorio' USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pigse.TENTE e
                    WHERE e.PK_ENTE = p_fk_ente AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El ente territorial (%) no existe o no esta activo', p_fk_ente
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_id_role IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.role r WHERE r.id_role = p_fk_id_role) THEN
        RAISE EXCEPTION 'El rol (%) no existe en public.role', p_fk_id_role USING ERRCODE = '23503';
    END IF;

    SELECT u.PK_TUSUARIO INTO v_pk_usuario
      FROM pigse.TUSUARIO u
     WHERE LOWER(u.CORREO_ELECTRONICO) = LOWER(TRIM(p_correo_electronico))
       AND u.ACTIVE = TRUE;

    IF v_pk_usuario IS NULL THEN
        SELECT us.id_user INTO v_id_user
          FROM public.users us
         WHERE LOWER(us.email) = LOWER(TRIM(p_correo_electronico));

        INSERT INTO pigse.TUSUARIO (
            FK_ID_USER, CORREO_ELECTRONICO, IDENTIFICACION, FK_TLV_TIPO_DOCUMENTO,
            PRIMER_NOMBRE, SEGUNDO_NOMBRE, PRIMER_APELLIDO, SEGUNDO_APELLIDO,
            TELEFONO, CREATED_BY, CREATED_AT, ACTIVE)
        VALUES (
            v_id_user, TRIM(p_correo_electronico), TRIM(p_identificacion),
            p_fk_tlv_tipo_documento, TRIM(p_primer_nombre), p_segundo_nombre,
            TRIM(p_primer_apellido), p_segundo_apellido, p_telefono,
            p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE)
        RETURNING PK_TUSUARIO INTO v_pk_usuario;
    END IF;

    IF p_fk_id_role IS NOT NULL THEN
        PERFORM pigse.fn_ente_usuario_crear(
            p_pk_usuario_solicitante, v_pk_usuario, p_fk_ente, p_fk_id_role);
    END IF;

    RETURN v_pk_usuario;
END;
$$;

-- ---------------------------------------------------------------------------
-- Arranque: espeja a quien ya tenga un rol PIGSE-* y no tenga TUSUARIO.
-- Cubre el estado actual del servidor; las altas nuevas pasan por las
-- funciones de arriba.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    r       RECORD;
    v_total INT := 0;
BEGIN
    FOR r IN
        SELECT DISTINCT us.email
          FROM public.users us
          JOIN public.role_users ru ON ru.user_id = us.id_user
          JOIN public.role rl       ON rl.id_role = ru.role_id
         WHERE rl.name LIKE 'PIGSE-%'
           AND NOT EXISTS (
               SELECT 1 FROM pigse.TUSUARIO u
                WHERE u.FK_ID_USER = us.id_user AND u.ACTIVE = TRUE)
    LOOP
        PERFORM pigse.fn_usuario_provisionar(r.email);
        v_total := v_total + 1;
    END LOOP;
    RAISE NOTICE 'V263 usuarios PIGSE espejados en pigse.TUSUARIO -> %', v_total;
END $$;

-- ---------------------------------------------------------------------------
-- Endpoints
-- ---------------------------------------------------------------------------
INSERT INTO public.query (uuid, query, type, microservice_id, path_template,
                          execution_mode, http_method, param_types)
SELECT 'pigse-usuarios-ente-crear',
       $q$SELECT pigse.fn_usuario_ente_crear(
              public.fn_get_pigse_usuario_id(CAST(:CONTEXT.USER_ID AS BIGINT)),
              CAST(:BODY.FK_TENTE AS BIGINT),
              CAST(:BODY.CORREO_ELECTRONICO AS VARCHAR),
              CAST(:BODY.IDENTIFICACION AS VARCHAR),
              CAST(:BODY.PRIMER_NOMBRE AS VARCHAR),
              CAST(:BODY.PRIMER_APELLIDO AS VARCHAR),
              CAST(:BODY.SEGUNDO_NOMBRE AS VARCHAR),
              CAST(:BODY.SEGUNDO_APELLIDO AS VARCHAR),
              CAST(:BODY.TELEFONO AS VARCHAR),
              CAST(:BODY.FK_TLV_TIPO_DOCUMENTO AS BIGINT),
              CAST(:BODY.FK_ID_ROLE AS BIGINT)
          ) AS "pkUsuario"$q$,
       'postgres', m.id_microservice, '/usuarios-ente', 'SELECT', 'POST',
       '{"BODY.FK_TENTE": "BIGINT!", "BODY.CORREO_ELECTRONICO": "VARCHAR!",
         "BODY.IDENTIFICACION": "VARCHAR!", "BODY.PRIMER_NOMBRE": "VARCHAR!",
         "BODY.PRIMER_APELLIDO": "VARCHAR!", "BODY.SEGUNDO_NOMBRE": "VARCHAR",
         "BODY.SEGUNDO_APELLIDO": "VARCHAR", "BODY.TELEFONO": "VARCHAR",
         "BODY.FK_TLV_TIPO_DOCUMENTO": "BIGINT", "BODY.FK_ID_ROLE": "BIGINT"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-usuarios-ente-crear');

INSERT INTO public.query (uuid, query, type, microservice_id, path_template,
                          execution_mode, http_method, param_types)
SELECT 'pigse-usuarios-provisionar',
       $q$SELECT pigse.fn_usuario_provisionar(
              CAST(:BODY.CORREO_ELECTRONICO AS VARCHAR)) AS "pkUsuario"$q$,
       'postgres', m.id_microservice, '/usuarios/provisionar', 'SELECT', 'POST',
       '{"BODY.CORREO_ELECTRONICO": "VARCHAR!"}'::jsonb
  FROM public.microservice m WHERE m.serviceid = 'pigse'
   AND NOT EXISTS (SELECT 1 FROM public.query WHERE uuid = 'pigse-usuarios-provisionar');

-- Mismo criterio que V258: solo los dos roles que el gate de las funciones
-- autoriza, y la lista de uuid explicita (nunca LIKE 'pigse-%', que alcanzaria
-- las filas originales de PIGSE).
INSERT INTO public.role_query (query_id, role_id)
SELECT q.id_query, ro.id_role
  FROM public.query q
 CROSS JOIN public.role ro
  JOIN public.microservice m
    ON m.id_microservice = q.microservice_id AND m.serviceid = 'pigse'
 WHERE q.uuid IN ('pigse-usuarios-ente-crear', 'pigse-usuarios-provisionar')
   AND ro.name IN ('PIGSE-ADMINISTRADOR', 'PIGSE-SECRETARIA_TERRITORIAL')
   AND NOT EXISTS (SELECT 1 FROM public.role_query rq
                    WHERE rq.query_id = q.id_query AND rq.role_id = ro.id_role);
