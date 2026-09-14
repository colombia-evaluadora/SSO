-- ============================================================================
-- V394 — Al crear un establecimiento en PIGSE (pigse.fn_est_crear), a
-- diferencia de academico_test.fn_est_crear (CEVAL, REV4/REV5), no se
-- creaba una sede por defecto ni se sincronizaba el rol PIGSE-RECTOR/
-- PIGSE-SECRETARIO del rector/secretaria en ella. El establecimiento
-- quedaba con FK_TFUNCIONARIO_RECTOR/SECRETARIA seteados pero sin ninguna
-- sede, y esas dos personas sin permiso efectivo en el sistema (los roles
-- de PIGSE se otorgan por sede via pigse.TSEDE_USUARIO, no por
-- establecimiento). pigse.fn_sed_crear ya sabe hacer todo eso solo --
-- lee el rector/secretaria de TESTABLECIMIENTO y llama a
-- fn_sede_usuario_crear -- solo faltaba que fn_est_crear la invocara,
-- igual que hace CEVAL con su propio fn_sed_crear.
-- ============================================================================

CREATE OR REPLACE FUNCTION pigse.fn_est_crear(p_pk_usuario_solicitante bigint, p_fk_ente bigint, p_nombre character varying, p_nit character varying, p_fk_tmunicipio bigint, p_codigo character varying, p_fk_tpropiedad_juridica bigint DEFAULT NULL::bigint, p_direccion character varying DEFAULT NULL::character varying, p_telefono character varying DEFAULT NULL::character varying, p_correo_electronico character varying DEFAULT NULL::character varying, p_fk_tlista_valor_zona bigint DEFAULT NULL::bigint, p_fk_testablecimiento_origen bigint DEFAULT NULL::bigint, p_fk_tfuncionario_rector bigint DEFAULT NULL::bigint, p_fk_tfuncionario_secretaria bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pigse', 'academico_test', 'public'
AS $function$
DECLARE
    v_pk_establecimiento BIGINT;
    v_fk_tlv_zona_sede_defecto BIGINT;
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

    IF NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'Nombre del establecimiento es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_nit), '') IS NULL THEN
        RAISE EXCEPTION 'NIT del establecimiento es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF NULLIF(TRIM(p_codigo), '') IS NULL THEN
        RAISE EXCEPTION 'Codigo del establecimiento es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_tmunicipio IS NULL THEN
        RAISE EXCEPTION 'Municipio (FK_TMUNICIPIO) es obligatorio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_ente IS NULL THEN
        RAISE EXCEPTION 'Ente territorial (FK_TENTE) es obligatorio' USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pigse.TENTE e
                    WHERE e.PK_ENTE = p_fk_ente AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'El ente territorial (%) no existe o no esta activo', p_fk_ente
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pigse.TMUNICIPIO m
                    WHERE m.PK_TMUNICIPIO = p_fk_tmunicipio) THEN
        RAISE EXCEPTION 'El municipio (%) no existe', p_fk_tmunicipio USING ERRCODE = '23503';
    END IF;

    IF p_fk_tpropiedad_juridica IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TPROPIEDAD_JURIDICA pj
                        WHERE pj.PK_PROPIEDAD_JURIDICA = p_fk_tpropiedad_juridica
                          AND pj.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La propiedad juridica (%) no existe o no esta activa', p_fk_tpropiedad_juridica
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tlista_valor_zona IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TLISTA_VALOR lv
                        WHERE lv.PK_LISTA_VALOR = p_fk_tlista_valor_zona
                          AND lv.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'La zona (%) no existe o no esta activa en TLISTA_VALOR', p_fk_tlista_valor_zona
            USING ERRCODE = '23503';
    END IF;

    IF p_fk_tfuncionario_rector IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TFUNCIONARIO f
                        WHERE f.PK_TFUNCIONARIO = p_fk_tfuncionario_rector) THEN
        RAISE EXCEPTION 'El funcionario rector (%) no existe', p_fk_tfuncionario_rector
            USING ERRCODE = '23503';
    END IF;
    IF p_fk_tfuncionario_secretaria IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pigse.TFUNCIONARIO f
                        WHERE f.PK_TFUNCIONARIO = p_fk_tfuncionario_secretaria) THEN
        RAISE EXCEPTION 'El funcionario secretaria (%) no existe', p_fk_tfuncionario_secretaria
            USING ERRCODE = '23503';
    END IF;

    IF EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO e
                WHERE e.NIT = TRIM(p_nit) AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'Ya existe un establecimiento activo con NIT %', p_nit
            USING ERRCODE = '23505';
    END IF;
    IF EXISTS (SELECT 1 FROM pigse.TESTABLECIMIENTO e
                WHERE e.CODIGO = TRIM(p_codigo) AND e.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'Ya existe un establecimiento activo con CODIGO %', p_codigo
            USING ERRCODE = '23505';
    END IF;

    INSERT INTO pigse.TESTABLECIMIENTO (
        NOMBRE, NIT, CODIGO, FK_TMUNICIPIO, FK_TPROPIEDAD_JURIDICA,
        DIRECCION, TELEFONO, CORREO_ELECTRONICO, FK_TLISTA_VALOR_ZONA,
        FK_TESTABLECIMIENTO_ORIGEN, FK_TFUNCIONARIO_RECTOR, FK_TFUNCIONARIO_SECRETARIA,
        CREATED_BY, CREATED_AT, ACTIVE
    )
    VALUES (
        TRIM(p_nombre), TRIM(p_nit), TRIM(p_codigo), p_fk_tmunicipio, p_fk_tpropiedad_juridica,
        p_direccion, p_telefono, p_correo_electronico, p_fk_tlista_valor_zona,
        p_fk_testablecimiento_origen, p_fk_tfuncionario_rector, p_fk_tfuncionario_secretaria,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_ESTABLECIMIENTO INTO v_pk_establecimiento;

    PERFORM pigse.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creacion del establecimiento %s', TRIM(p_nombre)), v_pk_establecimiento);

    INSERT INTO pigse.TENTE_ESTABLECIMIENTO (
        FK_TENTE, FK_TESTABLECIMIENTO, CREATED_BY, CREATED_AT, ACTIVE
    )
    SELECT p_fk_ente, v_pk_establecimiento, p_pk_usuario_solicitante::VARCHAR,
           CURRENT_TIMESTAMP, TRUE
     WHERE NOT EXISTS (
        SELECT 1 FROM pigse.TENTE_ESTABLECIMIENTO te
         WHERE te.FK_TENTE = p_fk_ente
           AND te.FK_TESTABLECIMIENTO = v_pk_establecimiento
           AND te.ACTIVE = TRUE
     );

    IF p_fk_tfuncionario_rector IS NOT NULL THEN
        UPDATE pigse.TFUNCIONARIO
           SET FK_TESTABLECIMIENTO = v_pk_establecimiento,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_rector
           AND FK_TESTABLECIMIENTO IS NULL;
    END IF;
    IF p_fk_tfuncionario_secretaria IS NOT NULL THEN
        UPDATE pigse.TFUNCIONARIO
           SET FK_TESTABLECIMIENTO = v_pk_establecimiento,
               MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
               MODIFIED_AT = CURRENT_TIMESTAMP
         WHERE PK_TFUNCIONARIO = p_fk_tfuncionario_secretaria
           AND FK_TESTABLECIMIENTO IS NULL;
    END IF;

    -- Sede por defecto (mismo CODIGO/NOMBRE que el EE) + sincroniza rector/
    -- secretaria en ella con su rol (PIGSE-RECTOR/PIGSE-SECRETARIO) -- mismo
    -- comportamiento que academico_test.fn_est_crear (paso 4/5, REV4/REV5).
    -- pigse.fn_sed_crear ya hace la sincronizacion de rol internamente (lee
    -- FK_TFUNCIONARIO_RECTOR/SECRETARIA de TESTABLECIMIENTO, que ya quedaron
    -- seteados arriba), asi que no hace falta duplicarla aca.
    SELECT PK_LISTA_VALOR INTO v_fk_tlv_zona_sede_defecto
      FROM pigse.TLISTA_VALOR
     WHERE CATEGORIA = 'ZONA' AND NOMBRE = 'Urbana y Rural' AND ACTIVE = TRUE
     LIMIT 1;

    IF v_fk_tlv_zona_sede_defecto IS NOT NULL THEN
        PERFORM pigse.fn_sed_crear(
            p_pk_usuario_solicitante,
            TRIM(p_codigo),
            TRIM(p_nombre),
            v_fk_tlv_zona_sede_defecto,
            v_pk_establecimiento
        );
    END IF;

    RETURN v_pk_establecimiento;
END;
$function$;

DO $$
DECLARE
    v_body TEXT;
BEGIN
    SELECT pg_get_functiondef(oid) INTO v_body
      FROM pg_proc WHERE proname = 'fn_est_crear' AND pronamespace = 'pigse'::regnamespace
       AND pg_get_function_arguments(oid) ILIKE '%p_fk_tfuncionario_rector%';

    IF v_body NOT ILIKE '%fn_sed_crear%' THEN
        RAISE EXCEPTION 'V394: fn_est_crear no quedo llamando a fn_sed_crear';
    END IF;

    RAISE NOTICE 'V394 OK: pigse.fn_est_crear crea la sede por defecto (y sincroniza roles) al crear un establecimiento.';
END $$;
