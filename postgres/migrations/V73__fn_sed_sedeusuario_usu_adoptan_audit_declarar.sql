-- V73 — adopta fn_audit_declarar en fn_sed_soft_delete, fn_sede_usuario_crear
-- y fn_usu_crear (docs/etiqueta-catalogo-funciones-fn.md §3/§4/§6).

CREATE OR REPLACE FUNCTION academico_test.fn_sed_soft_delete(p_pk_usuario_solicitante bigint, p_pk_sede bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_estado_actual BOOLEAN;
    v_fk_ee         BIGINT;
    v_usuarios     BIGINT := 0;
    v_niveles      BIGINT := 0;
    v_nombre        VARCHAR(130);
BEGIN
    SELECT ACTIVE, FK_TESTABLECIMIENTO, NOMBRE
      INTO v_estado_actual, v_fk_ee, v_nombre
      FROM academico_test.TSEDE
     WHERE PK_TSEDE = p_pk_sede;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe TSEDE con PK_TSEDE = %', p_pk_sede
            USING ERRCODE = 'P0002';
    END IF;

    IF v_estado_actual = FALSE THEN
        RAISE EXCEPTION 'TSEDE % ya se encuentra inactiva', p_pk_sede
            USING ERRCODE = '22023',
                  HINT    = 'Localice la sede mediante una consulta directa sobre TSEDE';
    END IF;

    IF academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TESTABLECIMIENTO e
            ON e.FK_TFUNCIONARIO_RECTOR = f.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_ee
           AND e.ACTIVE             = TRUE
           AND f.ACTIVE             = TRUE
           AND f.FK_TUSUARIO        = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TESTABLECIMIENTO e
            ON e.FK_TFUNCIONARIO_SECRETARIA = f.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_ee
           AND e.ACTIVE             = TRUE
           AND f.ACTIVE             = TRUE
           AND f.FK_TUSUARIO        = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TSEDE_USUARIO su
          JOIN academico_test.TSEDE s
            ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.FK_TESTABLECIMIENTO = v_fk_ee
           AND s.ACTIVE              = TRUE
           AND su.ACTIVE             = TRUE
           AND su.FK_TROL            = 8
           AND su.FK_TUSUARIO        = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSE
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante, format('Eliminación de la sede %s', COALESCE(v_nombre, p_pk_sede::TEXT)), v_fk_ee);

    UPDATE academico_test.TSEDE
       SET ACTIVE       = FALSE,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE PK_TSEDE = p_pk_sede;

    UPDATE academico_test.TSEDE_USUARIO
       SET ACTIVE       = FALSE,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE FK_TSEDE = p_pk_sede
       AND ACTIVE   = TRUE;

    GET DIAGNOSTICS v_usuarios = ROW_COUNT;

    UPDATE academico_test.TSEDE_NIVEL
       SET ACTIVE       = FALSE,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE FK_TSEDE = p_pk_sede
       AND ACTIVE   = TRUE;

    GET DIAGNOSTICS v_niveles = ROW_COUNT;

    RAISE NOTICE 'Soft delete TSEDE=% (autor: %): usuarios TSEDE_USUARIO afectados=%, niveles TSEDE_NIVEL afectados=%',
        p_pk_sede, p_pk_usuario_solicitante, v_usuarios, v_niveles;

    RETURN p_pk_sede;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_sede_usuario_crear(
    p_pk_usuario_solicitante bigint, p_fk_sede bigint, p_fk_rol bigint, p_fk_usuario bigint,
    p_orden numeric DEFAULT NULL::numeric, p_fk_tlv_jornada bigint DEFAULT NULL::bigint,
    p_tlv_estado character varying DEFAULT 'ACTIVO'::character varying, p_predeterminado numeric DEFAULT 0
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_pk_sede_usuario  BIGINT;
BEGIN
    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF p_fk_sede IS NULL THEN
        RAISE EXCEPTION 'sede (fk_sede) es obligatoria' USING ERRCODE = '23502';
    END IF;
    IF p_fk_rol IS NULL THEN
        RAISE EXCEPTION 'rol (fk_rol) es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_fk_usuario IS NULL THEN
        RAISE EXCEPTION 'usuario (fk_usuario) es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_orden IS NULL THEN
        RAISE EXCEPTION 'orden es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_fk_tlv_jornada IS NULL THEN
        RAISE EXCEPTION 'jornada (fk_tlv_jornada) es obligatoria' USING ERRCODE = '23502';
    END IF;

    IF p_tlv_estado NOT IN ('ACTIVO', 'INACTIVO') THEN
        RAISE EXCEPTION 'TLV_ESTADO (%) no es valido; se esperaba ACTIVO o INACTIVO',
            p_tlv_estado
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TSEDE
         WHERE PK_TSEDE = p_fk_sede
           AND ACTIVE   = TRUE
    ) THEN
        RAISE EXCEPTION 'TSEDE (%) no existe o no esta activa', p_fk_sede
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TROL
         WHERE PK_TROL = p_fk_rol
           AND ACTIVE  = TRUE
    ) THEN
        RAISE EXCEPTION 'TROL (%) no existe o no esta activo', p_fk_rol
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TUSUARIO
         WHERE PK_TUSUARIO = p_fk_usuario
           AND ACTIVE       = TRUE
    ) THEN
        RAISE EXCEPTION 'TUSUARIO (%) no existe o no esta activo', p_fk_usuario
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_jornada
           AND ACTIVE         = TRUE
    ) THEN
        RAISE EXCEPTION 'jornada/TLV (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_tlv_jornada
            USING ERRCODE = '23503';
    END IF;

    IF EXISTS (
        SELECT 1 FROM academico_test.TSEDE_USUARIO
         WHERE FK_TSEDE       = p_fk_sede
           AND FK_TROL        = p_fk_rol
           AND FK_TUSUARIO    = p_fk_usuario
           AND FK_TLV_JORNADA = p_fk_tlv_jornada
           AND ACTIVE         = TRUE
    ) THEN
        RAISE EXCEPTION 'ya existe un TSEDE_USUARIO activo para (sede=%, rol=%, usuario=%, jornada=%)',
            p_fk_sede, p_fk_rol, p_fk_usuario, p_fk_tlv_jornada
            USING ERRCODE = '23505';
    END IF;

    IF EXISTS (
        SELECT 1 FROM academico_test.TSEDE_USUARIO
         WHERE FK_TSEDE    = p_fk_sede
           AND FK_TROL     = p_fk_rol
           AND FK_TUSUARIO = p_fk_usuario
           AND ORDEN       = p_orden
           AND ACTIVE      = TRUE
    ) THEN
        RAISE EXCEPTION 'ya existe un TSEDE_USUARIO activo para (sede=%, rol=%, usuario=%, orden=%)',
            p_fk_sede, p_fk_rol, p_fk_usuario, p_orden
            USING ERRCODE = '23505';
    END IF;

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Asignación del rol %s al usuario %s en la sede %s', p_fk_rol, p_fk_usuario, p_fk_sede));

    INSERT INTO academico_test.TSEDE_USUARIO (
        FK_TSEDE, FK_TROL, FK_TUSUARIO,
        FK_TLV_JORNADA, ORDEN,
        TLV_ESTADO, PREDETERMINADO,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    VALUES (
        p_fk_sede, p_fk_rol, p_fk_usuario,
        p_fk_tlv_jornada, p_orden,
        p_tlv_estado, p_predeterminado,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TSEDE_USUARIO INTO v_pk_sede_usuario;

    RETURN v_pk_sede_usuario;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_usu_crear(
    p_pk_usuario_solicitante bigint, p_cuenta character varying, p_contrasena_hasheada character varying,
    p_fk_tlv_tipo_documento bigint, p_identificacion character varying,
    p_primer_nombre character varying DEFAULT NULL::character varying,
    p_segundo_nombre character varying DEFAULT NULL::character varying,
    p_primer_apellido character varying DEFAULT NULL::character varying,
    p_segundo_apellido character varying DEFAULT NULL::character varying,
    p_correo_electronico character varying DEFAULT NULL::character varying, p_fecha_nacimiento date DEFAULT NULL::date,
    p_fk_tlv_genero bigint DEFAULT NULL::bigint, p_telefono character varying DEFAULT NULL::character varying,
    p_fk_tarchivo_foto bigint DEFAULT NULL::bigint, p_visado character varying DEFAULT NULL::character varying
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_pk_usuario  BIGINT;
BEGIN
    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF p_cuenta IS NULL OR LENGTH(TRIM(p_cuenta)) = 0 THEN
        RAISE EXCEPTION 'cuenta es obligatoria' USING ERRCODE = '23502';
    END IF;
    IF p_contrasena_hasheada IS NULL OR LENGTH(TRIM(p_contrasena_hasheada)) = 0 THEN
        RAISE EXCEPTION 'contrasena es obligatoria' USING ERRCODE = '23502';
    END IF;
    IF p_fk_tlv_tipo_documento IS NULL THEN
        RAISE EXCEPTION 'tipo de documento (fk_tlv_tipo_documento) es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_identificacion IS NULL OR LENGTH(TRIM(p_identificacion)) = 0 THEN
        RAISE EXCEPTION 'identificacion es obligatoria' USING ERRCODE = '23502';
    END IF;
    IF p_primer_nombre IS NULL OR LENGTH(TRIM(p_primer_nombre)) = 0 THEN
        RAISE EXCEPTION 'primer_nombre es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_primer_apellido IS NULL OR LENGTH(TRIM(p_primer_apellido)) = 0 THEN
        RAISE EXCEPTION 'primer_apellido es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_fk_tlv_genero IS NULL THEN
        RAISE EXCEPTION 'genero (fk_tlv_genero) es obligatorio' USING ERRCODE = '23502';
    END IF;
    IF p_fecha_nacimiento IS NULL THEN
        RAISE EXCEPTION 'fecha_nacimiento es obligatoria' USING ERRCODE = '23502';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_tipo_documento
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'tipo de documento (%) no existe o no esta activo', p_fk_tlv_tipo_documento
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_tlv_genero
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'genero (%) no existe o no esta activo', p_fk_tlv_genero
            USING ERRCODE = '23503';
    END IF;

    IF EXISTS (
        SELECT 1 FROM academico_test.TUSUARIO
         WHERE UPPER(CUENTA) = UPPER(p_cuenta)
           AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'cuenta (%) ya esta registrada por un usuario activo', p_cuenta
            USING ERRCODE = '23505';
    END IF;

    IF EXISTS (
        SELECT 1 FROM academico_test.TUSUARIO
         WHERE FK_TLV_TIPO_DOCUMENTO = p_fk_tlv_tipo_documento
           AND IDENTIFICACION         = p_identificacion
           AND ACTIVE                  = TRUE
    ) THEN
        RAISE EXCEPTION 'ya existe un usuario activo con tipo_documento=%, identificacion=%',
            p_fk_tlv_tipo_documento, p_identificacion
            USING ERRCODE = '23505';
    END IF;

    IF p_fk_tarchivo_foto IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TARCHIVO
             WHERE PK_TARCHIVO = p_fk_tarchivo_foto
       )
    THEN
        RAISE EXCEPTION 'archivo de foto (%) no existe en TARCHIVO', p_fk_tarchivo_foto
            USING ERRCODE = '23503';
    END IF;

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Creación del usuario %s (cuenta %s)',
            TRIM(concat_ws(' ', p_primer_nombre, p_segundo_nombre, p_primer_apellido, p_segundo_apellido)), p_cuenta));

    INSERT INTO academico_test.TUSUARIO (
        CUENTA,
        CONTRASENA,
        ESTADO,
        VISADO,
        IDENTIFICACION,
        FK_TLV_TIPO_DOCUMENTO,
        PRIMER_NOMBRE,
        SEGUNDO_NOMBRE,
        PRIMER_APELLIDO,
        SEGUNDO_APELLIDO,
        CORREO_ELECTRONICO,
        FECHA_NACIMIENTO,
        FK_TLV_GENERO,
        TELEFONO,
        FK_TARCHIVO,
        CREATED_BY,
        CREATED_AT,
        ACTIVE
    )
    VALUES (
        p_cuenta,
        p_contrasena_hasheada,
        'A',
        p_visado,
        p_identificacion,
        p_fk_tlv_tipo_documento,
        p_primer_nombre,
        p_segundo_nombre,
        p_primer_apellido,
        p_segundo_apellido,
        p_correo_electronico,
        p_fecha_nacimiento,
        p_fk_tlv_genero,
        p_telefono,
        p_fk_tarchivo_foto,
        p_pk_usuario_solicitante::VARCHAR,
        CURRENT_TIMESTAMP,
        TRUE
    )
    RETURNING PK_TUSUARIO INTO v_pk_usuario;

    RETURN v_pk_usuario;
END;
$$;
