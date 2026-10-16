-- V558.1 — pigse.fn_fun_actualizar sincroniza el correo con public.users.
-- Que hace: al cambiar CORREO_ELECTRONICO mueve tambien users.email de la
--   cuenta SSO enlazada (FK_ID_USER); 23505 si otra cuenta ya usa ese correo.
-- Por que: en PIGSE no hay trigger equivalente a V215; la cuenta quedaba con
--   el correo viejo y reactivar/olvide contrasena/reenviar activacion no
--   encontraban cuenta con el nuevo (404, sin envio de correo).
-- Por que aqui y no en V390: V390 tambien define fn_fun_crear (redefinida en
--   V393); re-aplicarla revertiria V393. Misma firma: CREATE OR REPLACE.

CREATE OR REPLACE FUNCTION pigse.fn_fun_actualizar(
    p_pk_usuario_solicitante bigint,
    p_pk_funcionario bigint,
    p_correo_electronico character varying DEFAULT NULL::character varying,
    p_identificacion character varying DEFAULT NULL::character varying,
    p_primer_nombre character varying DEFAULT NULL::character varying,
    p_segundo_nombre character varying DEFAULT NULL::character varying,
    p_primer_apellido character varying DEFAULT NULL::character varying,
    p_segundo_apellido character varying DEFAULT NULL::character varying,
    p_telefono character varying DEFAULT NULL::character varying,
    p_fk_tlv_tipo_documento bigint DEFAULT NULL::bigint,
    p_fk_tlv_cargo bigint DEFAULT NULL::bigint,
    p_fk_establecimiento bigint DEFAULT NULL::bigint,
    p_fk_tlv_clase_funcionario bigint DEFAULT NULL::bigint,
    p_fk_tlv_nivel_ensenanza bigint DEFAULT NULL::bigint,
    p_fk_tlv_grado_escalafon bigint DEFAULT NULL::bigint,
    p_fk_tlv_nivel_educativo bigint DEFAULT NULL::bigint,
    p_fk_tlv_fuente_recurso bigint DEFAULT NULL::bigint,
    p_fk_tlv_tipo_vinculacion bigint DEFAULT NULL::bigint,
    p_fk_tlv_cargo_funcional bigint DEFAULT NULL::bigint,
    p_direccion character varying DEFAULT NULL::character varying
)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO 'pigse', 'public'
AS $function$
DECLARE
    v_pk_usuario BIGINT;
    v_fk_id_user BIGINT;
BEGIN
    SELECT f.FK_TUSUARIO INTO v_pk_usuario
      FROM pigse.TFUNCIONARIO f WHERE f.PK_TFUNCIONARIO = p_pk_funcionario AND f.ACTIVE = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontro el funcionario solicitado (%)', p_pk_funcionario USING ERRCODE = 'P0002';
    END IF;

    PERFORM pigse.fn_assert_permiso_funcionario(p_pk_usuario_solicitante, 'EDITAR', p_pk_funcionario);

    IF p_fk_establecimiento IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO WHERE PK_ESTABLECIMIENTO = p_fk_establecimiento AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El establecimiento (%) no existe o no esta activo', p_fk_establecimiento USING ERRCODE = '23503';
    END IF;

    IF p_correo_electronico IS NOT NULL AND EXISTS (
        SELECT 1 FROM pigse.TUSUARIO WHERE UPPER(CORREO_ELECTRONICO) = UPPER(TRIM(p_correo_electronico)) AND ACTIVE = TRUE AND PK_TUSUARIO <> v_pk_usuario
    ) THEN
        RAISE EXCEPTION 'Ya existe otro usuario activo con el correo %', p_correo_electronico USING ERRCODE = '23505';
    END IF;

    UPDATE pigse.TUSUARIO
       SET CORREO_ELECTRONICO = COALESCE(TRIM(p_correo_electronico), CORREO_ELECTRONICO),
           IDENTIFICACION     = COALESCE(TRIM(p_identificacion), IDENTIFICACION),
           FK_TLV_TIPO_DOCUMENTO = COALESCE(p_fk_tlv_tipo_documento, FK_TLV_TIPO_DOCUMENTO),
           PRIMER_NOMBRE      = COALESCE(TRIM(p_primer_nombre), PRIMER_NOMBRE),
           SEGUNDO_NOMBRE     = COALESCE(p_segundo_nombre, SEGUNDO_NOMBRE),
           PRIMER_APELLIDO    = COALESCE(TRIM(p_primer_apellido), PRIMER_APELLIDO),
           SEGUNDO_APELLIDO   = COALESCE(p_segundo_apellido, SEGUNDO_APELLIDO),
           TELEFONO           = COALESCE(p_telefono, TELEFONO),
           MODIFIED_BY        = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TUSUARIO = v_pk_usuario
    RETURNING FK_ID_USER INTO v_fk_id_user;

    -- El correo de login vive en public.users y en PIGSE no hay trigger que
    -- lo sincronice desde TUSUARIO (V215 solo cubre academico_test). Sin esto
    -- un cambio de correo dejaba TUSUARIO con el correo nuevo y la cuenta SSO
    -- con el viejo: "olvide contrasena"/"reenviar activacion" con el correo
    -- nuevo no encontraban cuenta (404, no se enviaba nada) y
    -- reactivar-por-cambio-de-correo se rechazaba porque "todavia existe una
    -- cuenta con el correo anterior". Se mueve users.email aca, en la misma
    -- transaccion, y el front luego llama a reactivar-por-cambio-de-correo.
    IF p_correo_electronico IS NOT NULL AND v_fk_id_user IS NOT NULL THEN
        IF EXISTS (
            SELECT 1 FROM public.users
             WHERE UPPER(email) = UPPER(TRIM(p_correo_electronico)) AND id_user <> v_fk_id_user
        ) THEN
            RAISE EXCEPTION 'Ya existe otra cuenta con el correo %', TRIM(p_correo_electronico) USING ERRCODE = '23505';
        END IF;

        UPDATE public.users
           SET email = TRIM(p_correo_electronico)
         WHERE id_user = v_fk_id_user
           AND email IS DISTINCT FROM TRIM(p_correo_electronico);
    END IF;

    UPDATE pigse.TFUNCIONARIO
       SET FK_TESTABLECIMIENTO     = COALESCE(p_fk_establecimiento, FK_TESTABLECIMIENTO),
           FK_TLV_CARGO            = COALESCE(p_fk_tlv_cargo, FK_TLV_CARGO),
           FK_TLV_CLASE_FUNCIONARIO = COALESCE(p_fk_tlv_clase_funcionario, FK_TLV_CLASE_FUNCIONARIO),
           FK_TLV_NIVEL_ENSENANZA  = COALESCE(p_fk_tlv_nivel_ensenanza, FK_TLV_NIVEL_ENSENANZA),
           FK_TLV_GRADO_ESCALAFON  = COALESCE(p_fk_tlv_grado_escalafon, FK_TLV_GRADO_ESCALAFON),
           FK_TLV_NIVEL_EDUCATIVO  = COALESCE(p_fk_tlv_nivel_educativo, FK_TLV_NIVEL_EDUCATIVO),
           FK_TLV_FUENTE_RECURSO   = COALESCE(p_fk_tlv_fuente_recurso, FK_TLV_FUENTE_RECURSO),
           FK_TLV_TIPO_VINCULACION = COALESCE(p_fk_tlv_tipo_vinculacion, FK_TLV_TIPO_VINCULACION),
           FK_TLV_CARGO_FUNCIONAL = COALESCE(p_fk_tlv_cargo_funcional, FK_TLV_CARGO_FUNCIONAL),
           DIRECCION               = COALESCE(p_direccion, DIRECCION),
           MODIFIED_BY             = p_pk_usuario_solicitante::VARCHAR, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TFUNCIONARIO = p_pk_funcionario;

    RETURN TRUE;
END;
$function$;
