-- ============================================================================
-- V393 — pigse.fn_fun_crear nunca seteaba FK_ID_USER al insertar en
-- pigse.TUSUARIO, así que el puente public.fn_get_pigse_usuario_id(idUser)
-- nunca resolvía al usuario recién creado (RegisterResponse.pkTusuario
-- volvía siempre null). El caller real, FuncionarioRegistrationService
-- .registerFuncionarioPigse, SIEMPRE crea/reusa la fila de public.users
-- ANTES de llamar a esta función (mismo correo), así que alcanza con
-- resolver el id_user por correo dentro de la función misma -- sin tocar
-- la firma ni el caller Java (que ya no pasa ese dato explícitamente; el
-- diseño "correcto" sería agregarle un parámetro, como hace
-- academico_test.fn_usu_crear vía p_contrasena_hasheada, pero eso implica
-- tocar Java y no hace falta para cerrar el bug real).
-- ============================================================================

CREATE OR REPLACE FUNCTION pigse.fn_fun_crear(p_pk_usuario_solicitante bigint, p_correo_electronico character varying, p_identificacion character varying, p_primer_nombre character varying, p_primer_apellido character varying, p_segundo_nombre character varying DEFAULT NULL::character varying, p_segundo_apellido character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_fk_tlv_tipo_documento bigint DEFAULT NULL::bigint, p_fk_tlv_cargo bigint DEFAULT NULL::bigint, p_fk_establecimiento bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'pigse', 'public'
AS $function$
DECLARE
    v_pk_usuario BIGINT;
    v_pk_funcionario BIGINT;
    v_fk_id_user BIGINT;
BEGIN
    PERFORM pigse.fn_assert_permiso_funcionario(p_pk_usuario_solicitante, 'CREAR', NULL);

    IF p_fk_establecimiento IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO WHERE PK_ESTABLECIMIENTO = p_fk_establecimiento AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El establecimiento (%) no existe o no esta activo', p_fk_establecimiento USING ERRCODE = '23503';
    END IF;

    IF EXISTS (SELECT 1 FROM pigse.TUSUARIO WHERE UPPER(CORREO_ELECTRONICO) = UPPER(TRIM(p_correo_electronico)) AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'Ya existe otro usuario activo con el correo %', p_correo_electronico USING ERRCODE = '23505';
    END IF;

    -- Puente hacia public.users: el caller (FuncionarioRegistrationService,
    -- registerFuncionarioPigse) SIEMPRE crea/reusa la fila de public.users
    -- con este mismo correo ANTES de llamar a esta funcion.
    SELECT id_user INTO v_fk_id_user
      FROM public.users
     WHERE UPPER(email) = UPPER(TRIM(p_correo_electronico))
     ORDER BY id_user DESC
     LIMIT 1;

    INSERT INTO pigse.TUSUARIO (
        CORREO_ELECTRONICO, IDENTIFICACION, FK_TLV_TIPO_DOCUMENTO,
        PRIMER_NOMBRE, SEGUNDO_NOMBRE, PRIMER_APELLIDO, SEGUNDO_APELLIDO, TELEFONO,
        FK_ID_USER, CREATED_BY
    ) VALUES (
        TRIM(p_correo_electronico), TRIM(p_identificacion), p_fk_tlv_tipo_documento,
        TRIM(p_primer_nombre), p_segundo_nombre, TRIM(p_primer_apellido), p_segundo_apellido, p_telefono,
        v_fk_id_user, p_pk_usuario_solicitante::VARCHAR
    ) RETURNING PK_TUSUARIO INTO v_pk_usuario;

    INSERT INTO pigse.TFUNCIONARIO (FK_TUSUARIO, FK_TESTABLECIMIENTO, FK_TLV_CARGO, CREATED_BY)
    VALUES (v_pk_usuario, p_fk_establecimiento, p_fk_tlv_cargo, p_pk_usuario_solicitante::VARCHAR)
    RETURNING PK_TFUNCIONARIO INTO v_pk_funcionario;

    RETURN v_pk_funcionario;
END;
$function$;

DO $$
DECLARE
    v_body TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_body
      FROM pg_proc WHERE proname = 'fn_fun_crear' AND pronamespace = 'pigse'::regnamespace;

    IF v_body NOT ILIKE '%FK_ID_USER%' THEN
        RAISE EXCEPTION 'V393: fn_fun_crear no quedo seteando FK_ID_USER';
    END IF;

    RAISE NOTICE 'V393 OK: pigse.fn_fun_crear ahora resuelve y setea FK_ID_USER al crear TUSUARIO.';
END $$;

-- Backfill: filas de pigse.TUSUARIO creadas antes de este fix (por lo tanto
-- con FK_ID_USER null) se enlazan retroactivamente por correo contra
-- public.users, mismo criterio que usa la funcion de aqui en adelante.
UPDATE pigse.TUSUARIO u
   SET FK_ID_USER = usr.id_user
  FROM public.users usr
 WHERE UPPER(u.CORREO_ELECTRONICO) = UPPER(usr.email)
   AND u.FK_ID_USER IS NULL
   AND u.ACTIVE = TRUE;
