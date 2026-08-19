-- V72 — adopta fn_audit_declarar en las funciones pequeñas de
-- establecimiento/funcionario/sede-usuario/catálogo de listas de valor
-- (docs/etiqueta-catalogo-funciones-fn.md §4/§5/§18). Estas usan
-- fn_puede_afectar_establecimiento/fn_puede_afectar_usuarios (sin id de
-- establecimiento explícito), así que — a diferencia de los módulos
-- anteriores — no hay un establecimiento_id barato para reutilizar; se
-- declara solo actor+etiqueta (establecimiento queda NULL) en esta pasada.
--
-- fn_fun_soft_delete se excluye a propósito: no hace DML propio, solo
-- delega en fn_sede_usuario_soft_delete (que ya declara su propia
-- etiqueta) — declarar aquí sería una etiqueta que la llamada interna
-- pisaría de inmediato (ver nota de "última llamada gana", V69).

CREATE OR REPLACE FUNCTION academico_test.fn_delete_plan_from_value(p_user_pk bigint, p_nombre character varying)
RETURNS TABLE(pk_lista_valor bigint, nombre character varying, was_deleted boolean)
LANGUAGE plpgsql SET search_path TO 'academico_test', 'public' AS $$
DECLARE
    v_valor VARCHAR;
    v_pk    BIGINT;
    v_rows  INTEGER;
BEGIN
    -- Autorizacion: solo superadministradores.
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    IF p_nombre IS NULL OR LENGTH(TRIM(p_nombre)) = 0 THEN
        RAISE EXCEPTION 'fn_delete_plan_from_value: p_nombre es obligatorio';
    END IF;

    v_valor := UPPER(REGEXP_REPLACE(TRIM(p_nombre), '\s+', '_', 'g'));

    -- Lookup del plan activo en la seccion PLAN. Alias lv.* para evitar
    -- la colision con el parametro OUT `pk_lista_valor` de RETURNS TABLE.
    SELECT lv.pk_lista_valor
      INTO v_pk
      FROM academico_test.tlista_valor lv
     WHERE lv.categoria   = 'PLAN'
       AND UPPER(TRIM(lv.valor)) = v_valor
       AND lv.active      = TRUE
     LIMIT 1;

    IF v_pk IS NOT NULL THEN
        PERFORM academico_test.fn_audit_declarar(
            p_user_pk, format('Eliminación del valor de catálogo "%s" (plan de estudio)', p_nombre));

        UPDATE academico_test.tlista_valor lv
           SET active      = FALSE,
               modified_by = CURRENT_USER,
               modified_at = CURRENT_TIMESTAMP
         WHERE lv.pk_lista_valor = v_pk;

        GET DIAGNOSTICS v_rows = ROW_COUNT;
        was_deleted := (v_rows > 0);
    ELSE
        was_deleted := FALSE;
    END IF;

    pk_lista_valor := v_pk;
    nombre         := TRIM(p_nombre);
    RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_sede_usuario_soft_delete(p_pk_sede_usuario bigint, p_pk_usuario_solicitante bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_active  BOOLEAN;
BEGIN
    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT ACTIVE
      INTO v_active
      FROM academico_test.TSEDE_USUARIO
     WHERE PK_TSEDE_USUARIO = p_pk_sede_usuario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'no existe TSEDE_USUARIO con PK %', p_pk_sede_usuario
            USING ERRCODE = 'P0002';
    END IF;

    IF v_active = FALSE THEN
        -- ya estaba inactivo: idempotente, no error.
        RETURN p_pk_sede_usuario;
    END IF;

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante, format('Eliminación de la asignación de sede/rol %s', p_pk_sede_usuario));

    UPDATE academico_test.TSEDE_USUARIO
       SET ACTIVE      = FALSE,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TSEDE_USUARIO = p_pk_sede_usuario;

    RETURN p_pk_sede_usuario;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_create_plan_from_value(p_user_pk bigint, p_nombre character varying)
RETURNS TABLE(pk_lista_valor bigint, nombre character varying, valor character varying, status character varying)
LANGUAGE plpgsql SET search_path TO 'academico_test', 'public' AS $$
DECLARE
    v_nombre    VARCHAR;
    v_valor     VARCHAR;
    v_pk        BIGINT;
    v_existente BIGINT;
BEGIN
    -- Autorizacion: solo superadministradores.
    PERFORM academico_test.fn_assert_superadmin(p_user_pk);

    IF p_nombre IS NULL OR LENGTH(TRIM(p_nombre)) = 0 THEN
        RAISE EXCEPTION 'fn_create_plan_from_value: p_nombre es obligatorio';
    END IF;
    v_nombre := TRIM(p_nombre);

    -- Mismo patron de derivacion de codigo que fn_add_trol /
    -- fn_create_parent_menu_with_submenus.
    v_valor := LEFT(UPPER(REGEXP_REPLACE(v_nombre, '\s+', '_', 'g')), 30);

    -- Verificacion explicita de duplicado (case-insensitive en VALOR)
    -- sobre la seccion CATEGORIA='PLAN'. Alias lv.* para evitar la
    -- colision con el parametro OUT `pk_lista_valor` de RETURNS TABLE.
    SELECT lv.pk_lista_valor
      INTO v_existente
      FROM academico_test.tlista_valor lv
     WHERE lv.categoria = 'PLAN'
       AND UPPER(TRIM(lv.valor)) = v_valor
       AND lv.active = TRUE
     LIMIT 1;

    IF v_existente IS NOT NULL THEN
        RAISE EXCEPTION 'fn_create_plan_from_value: ya existe un plan activo con valor=% (pk_lista_valor=%)',
            v_valor, v_existente;
    END IF;

    PERFORM academico_test.fn_audit_declarar(
        p_user_pk, format('Creación del valor de catálogo "%s" (plan de estudio)', v_nombre));

    INSERT INTO academico_test.tlista_valor (
        categoria, nombre, valor, created_by
    )
    VALUES (
        'PLAN', v_nombre, v_valor, CURRENT_USER
    )
    RETURNING academico_test.tlista_valor.pk_lista_valor,
              academico_test.tlista_valor.nombre,
              academico_test.tlista_valor.valor
      INTO v_pk, nombre, valor;

    pk_lista_valor := v_pk;
    status         := 'inserted';
    RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_sed_soft_delete_bulk(p_pk_usuario_solicitante bigint, p_pks bigint[])
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_pk        BIGINT;
    v_procesados BIGINT := 0;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF p_pks IS NULL OR CARDINALITY(p_pks) = 0 THEN
        RAISE EXCEPTION 'p_pks es obligatorio y debe contener al menos un PK_TSEDE'
            USING ERRCODE = '22023';
    END IF;

    IF (SELECT COUNT(*) FROM (SELECT unnest(p_pks)) AS x) <> CARDINALITY(p_pks) THEN
        RAISE EXCEPTION 'p_pks contiene PKs duplicados'
            USING ERRCODE = '22023',
                  HINT    = 'Elimine duplicados antes de invocar la funcion';
    END IF;

    IF EXISTS (SELECT 1 FROM unnest(p_pks) AS pk WHERE pk IS NULL OR pk <= 0) THEN
        RAISE EXCEPTION 'p_pks contiene elementos nulos o <= 0'
            USING ERRCODE = '22023';
    END IF;

    -- Etiqueta agregada para el lote; cada fn_sed_soft_delete individual
    -- declara la suya propia por sede al ejecutarse (ultima llamada gana),
    -- asi que esta queda como contexto general antes de que arranque el loop.
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante, format('Eliminación masiva de %s sedes', CARDINALITY(p_pks)));

    FOREACH v_pk IN ARRAY p_pks
    LOOP
        PERFORM academico_test.fn_sed_soft_delete(p_pk_usuario_solicitante, v_pk);
        v_procesados := v_procesados + 1;
    END LOOP;

    RAISE NOTICE 'Soft delete bulk TSEDE: autor=%, pks=% (procesados=%)',
        p_pk_usuario_solicitante, p_pks, v_procesados;

    RETURN v_procesados;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_fun_crear(
    p_pk_usuario_solicitante bigint, p_correo_electronico character varying, p_contrasena_hasheada character varying,
    p_fk_tlv_tipo_documento bigint, p_identificacion character varying,
    p_primer_nombre character varying DEFAULT NULL::character varying,
    p_segundo_nombre character varying DEFAULT NULL::character varying,
    p_primer_apellido character varying DEFAULT NULL::character varying,
    p_segundo_apellido character varying DEFAULT NULL::character varying,
    p_fecha_nacimiento date DEFAULT NULL::date, p_fk_tlv_genero bigint DEFAULT NULL::bigint,
    p_telefono character varying DEFAULT NULL::character varying, p_fk_tarchivo_foto bigint DEFAULT NULL::bigint,
    p_visado character varying DEFAULT NULL::character varying, p_fk_tmunicipio_expedicion bigint DEFAULT NULL::bigint
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_pk_usuario      BIGINT;
    v_pk_funcionario  BIGINT;
BEGIN
    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    IF p_correo_electronico IS NULL OR LENGTH(TRIM(p_correo_electronico)) = 0 THEN
        RAISE EXCEPTION 'correo_electronico es obligatorio: la cuenta del funcionario es su correo'
            USING ERRCODE = '23502';
    END IF;

    IF p_fk_tmunicipio_expedicion IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TMUNICIPIO
         WHERE PK_TMUNICIPIO = p_fk_tmunicipio_expedicion
    ) THEN
        RAISE EXCEPTION 'municipio de expedicion (%) no existe en TMUNICIPIO',
            p_fk_tmunicipio_expedicion
            USING ERRCODE = '23503';
    END IF;

    -- fn_usu_crear declara su propia etiqueta para el INSERT en TUSUARIO
    -- que hace internamente; la de abajo (para el INSERT en TFUNCIONARIO
    -- de esta funcion) la sobreescribe despues, correctamente.
    v_pk_usuario := academico_test.fn_usu_crear(
        p_pk_usuario_solicitante  := p_pk_usuario_solicitante,
        p_cuenta                  := p_correo_electronico,
        p_contrasena_hasheada     := p_contrasena_hasheada,
        p_fk_tlv_tipo_documento   := p_fk_tlv_tipo_documento,
        p_identificacion          := p_identificacion,
        p_primer_nombre           := p_primer_nombre,
        p_segundo_nombre          := p_segundo_nombre,
        p_primer_apellido         := p_primer_apellido,
        p_segundo_apellido        := p_segundo_apellido,
        p_correo_electronico      := p_correo_electronico,
        p_fecha_nacimiento        := p_fecha_nacimiento,
        p_fk_tlv_genero           := p_fk_tlv_genero,
        p_telefono                := p_telefono,
        p_fk_tarchivo_foto        := p_fk_tarchivo_foto,
        p_visado                  := p_visado
    );

    IF EXISTS (
        SELECT 1 FROM academico_test.TFUNCIONARIO
         WHERE FK_TUSUARIO = v_pk_usuario
           AND ACTIVE      = TRUE
    ) THEN
        RAISE EXCEPTION 'el usuario (%) ya es funcionario activo', v_pk_usuario
            USING ERRCODE = '23505';
    END IF;

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Creación del funcionario %s', TRIM(concat_ws(' ', p_primer_nombre, p_segundo_nombre, p_primer_apellido, p_segundo_apellido))));

    INSERT INTO academico_test.TFUNCIONARIO (
        FK_TMUNICIPIO_EXPEDICION, FK_TUSUARIO, CREATED_BY, CREATED_AT, ACTIVE
    )
    VALUES (
        p_fk_tmunicipio_expedicion, v_pk_usuario,
        p_pk_usuario_solicitante::VARCHAR, CURRENT_TIMESTAMP, TRUE
    )
    RETURNING PK_TFUNCIONARIO INTO v_pk_funcionario;

    RETURN v_pk_funcionario;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_est_soft_delete_bulk(p_pk_usuario_solicitante bigint, p_pks bigint[])
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_pk         BIGINT;
    v_procesados BIGINT := 0;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;

    IF p_pks IS NULL OR CARDINALITY(p_pks) = 0 THEN
        RAISE EXCEPTION 'p_pks es obligatorio y debe contener al menos un PK_ESTABLECIMIENTO'
            USING ERRCODE = '22023';
    END IF;

    IF (SELECT COUNT(*) FROM (SELECT unnest(p_pks)) AS x) <> CARDINALITY(p_pks) THEN
        RAISE EXCEPTION 'p_pks contiene PKs duplicados'
            USING ERRCODE = '22023',
                  HINT    = 'Elimine duplicados antes de invocar la funcion';
    END IF;

    IF EXISTS (SELECT 1 FROM unnest(p_pks) AS pk WHERE pk IS NULL OR pk <= 0) THEN
        RAISE EXCEPTION 'p_pks contiene elementos nulos o <= 0'
            USING ERRCODE = '22023';
    END IF;

    IF NOT academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante, format('Eliminación masiva de %s establecimientos', CARDINALITY(p_pks)));

    FOREACH v_pk IN ARRAY p_pks
    LOOP
        PERFORM academico_test.fn_est_soft_delete(p_pk_usuario_solicitante, v_pk);
        v_procesados := v_procesados + 1;
    END LOOP;

    RAISE NOTICE 'Soft delete bulk TESTABLECIMIENTO: autor=%, pks=% (procesados=%)',
        p_pk_usuario_solicitante, p_pks, v_procesados;

    RETURN v_procesados;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_est_soft_delete(p_pk_usuario_solicitante bigint, p_pk_establecimiento bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_estado_actual BOOLEAN;
    v_sedes         BIGINT := 0;
    v_pk_sede       BIGINT;
    v_nombre        VARCHAR(130);
BEGIN
    IF NOT academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT ACTIVE, NOMBRE
      INTO v_estado_actual, v_nombre
      FROM academico_test.TESTABLECIMIENTO
     WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe TESTABLECIMIENTO con PK_ESTABLECIMIENTO = %', p_pk_establecimiento
            USING ERRCODE = 'P0002';
    END IF;

    IF v_estado_actual = FALSE THEN
        RAISE EXCEPTION 'TESTABLECIMIENTO % ya se encuentra inactivo', p_pk_establecimiento
            USING ERRCODE = '22023',
                  HINT    = 'Use fn_est_buscar_por_nit(..., p_incluir_inactivos=TRUE) para localizar registros dados de baja';
    END IF;

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante, format('Eliminación del establecimiento %s', COALESCE(v_nombre, p_pk_establecimiento::TEXT)));

    UPDATE academico_test.TESTABLECIMIENTO
       SET ACTIVE       = FALSE,
           MODIFIED_BY  = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT  = CURRENT_TIMESTAMP
     WHERE PK_ESTABLECIMIENTO = p_pk_establecimiento;

    -- Cascade a las sedes del EE (cada una declara su propia etiqueta al
    -- ejecutarse — ver V73 fn_sed_soft_delete).
    FOR v_pk_sede IN
        SELECT PK_TSEDE
          FROM academico_test.TSEDE
         WHERE FK_TESTABLECIMIENTO = p_pk_establecimiento
           AND ACTIVE = TRUE
         ORDER BY PK_TSEDE
    LOOP
        PERFORM academico_test.fn_sed_soft_delete(v_pk_sede, p_pk_usuario_solicitante);
        v_sedes := v_sedes + 1;
    END LOOP;

    RAISE NOTICE 'Soft delete TESTABLECIMIENTO=% (autor: %): sedes dadas de baja via V52=%',
        p_pk_establecimiento, p_pk_usuario_solicitante, v_sedes;

    RETURN p_pk_establecimiento;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_fun_enlazar_establecimiento(
    p_pk_usuario_solicitante bigint, p_pk_funcionario bigint, p_fk_establecimiento bigint
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_pk_funcionario      BIGINT;
    v_fk_establecimiento  BIGINT := COALESCE(
        p_fk_establecimiento,
        academico_test.fn_resolver_establecimiento_unico(p_pk_usuario_solicitante)
    );
    v_est_nombre VARCHAR(130); v_func_nombre TEXT;
BEGIN
    IF p_pk_usuario_solicitante IS NULL OR p_pk_usuario_solicitante <= 0 THEN
        RAISE EXCEPTION 'p_pk_usuario_solicitante es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF p_pk_funcionario IS NULL OR p_pk_funcionario <= 0 THEN
        RAISE EXCEPTION 'p_pk_funcionario es obligatorio y debe ser > 0'
            USING ERRCODE = '22023';
    END IF;
    IF v_fk_establecimiento IS NULL THEN
        RAISE EXCEPTION 'p_fk_establecimiento es obligatorio y no se pudo resolver automaticamente (el solicitante no esta ligado a exactamente un EE como rector/secretaria/jefe de sistema)'
            USING ERRCODE = '22023';
    END IF;

    SELECT NOMBRE INTO v_est_nombre FROM academico_test.TESTABLECIMIENTO
     WHERE PK_ESTABLECIMIENTO = v_fk_establecimiento AND ACTIVE = TRUE;
    IF v_est_nombre IS NULL THEN
        RAISE EXCEPTION 'No existe un TESTABLECIMIENTO activo con PK %', v_fk_establecimiento
            USING ERRCODE = '22023';
    END IF;

    IF academico_test.fn_puede_afectar_establecimiento(p_pk_usuario_solicitante) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TESTABLECIMIENTO e ON e.FK_TFUNCIONARIO_RECTOR = f.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento
           AND e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TESTABLECIMIENTO e ON e.FK_TFUNCIONARIO_SECRETARIA = f.PK_TFUNCIONARIO
         WHERE e.PK_ESTABLECIMIENTO = v_fk_establecimiento
           AND e.ACTIVE = TRUE AND f.ACTIVE = TRUE AND f.FK_TUSUARIO = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSIF EXISTS (
        SELECT 1
          FROM academico_test.TSEDE_USUARIO su
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = su.FK_TSEDE
         WHERE s.FK_TESTABLECIMIENTO = v_fk_establecimiento
           AND s.ACTIVE = TRUE AND su.ACTIVE = TRUE AND su.FK_TROL = 8
           AND su.FK_TUSUARIO = p_pk_usuario_solicitante
    ) THEN
        NULL;
    ELSE
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    -- REV3: recibe el PK_TFUNCIONARIO exacto devuelto por /register/funcionario
    -- (antes lo buscaba por FK_TUSUARIO + FK_ESTABLECIMIENTO IS NULL LIMIT 1,
    -- ambiguo si llegara a haber mas de un TFUNCIONARIO pendiente a la vez
    -- para el mismo usuario). El IS NULL se mantiene como chequeo de
    -- seguridad: no permite re-enlazar un TFUNCIONARIO que ya tiene EE.
    SELECT f.PK_TFUNCIONARIO, TRIM(concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO))
      INTO v_pk_funcionario, v_func_nombre
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
     WHERE f.PK_TFUNCIONARIO = p_pk_funcionario
       AND f.FK_ESTABLECIMIENTO IS NULL
       AND f.ACTIVE = TRUE;

    IF v_pk_funcionario IS NULL THEN
        RAISE EXCEPTION 'No existe un TFUNCIONARIO pendiente de enlazar (activo, sin FK_ESTABLECIMIENTO) con PK %', p_pk_funcionario
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Vinculación del funcionario %s al establecimiento %s', COALESCE(v_func_nombre, p_pk_funcionario::TEXT), v_est_nombre),
        v_fk_establecimiento);

    UPDATE academico_test.TFUNCIONARIO
       SET FK_ESTABLECIMIENTO = v_fk_establecimiento,
           MODIFIED_BY = p_pk_usuario_solicitante::VARCHAR,
           MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TFUNCIONARIO = v_pk_funcionario;

    RETURN v_pk_funcionario;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_sede_usuario_actualizar(
    p_pk_sede_usuario bigint, p_pk_usuario_solicitante bigint, p_orden numeric DEFAULT NULL::numeric,
    p_fk_tlv_jornada bigint DEFAULT NULL::bigint, p_tlv_estado character varying DEFAULT NULL::character varying,
    p_predeterminado numeric DEFAULT NULL::numeric
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_active  BOOLEAN;
BEGIN
    IF NOT academico_test.fn_puede_afectar_usuarios(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;

    SELECT ACTIVE
      INTO v_active
      FROM academico_test.TSEDE_USUARIO
     WHERE PK_TSEDE_USUARIO = p_pk_sede_usuario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'no existe TSEDE_USUARIO con PK %', p_pk_sede_usuario
            USING ERRCODE = 'P0002';
    END IF;

    IF v_active = FALSE THEN
        RAISE EXCEPTION 'TSEDE_USUARIO % esta inactivo; no se puede actualizar', p_pk_sede_usuario
            USING ERRCODE = '22023';
    END IF;

    IF p_tlv_estado IS NOT NULL AND p_tlv_estado NOT IN ('ACTIVO', 'INACTIVO') THEN
        RAISE EXCEPTION 'TLV_ESTADO (%) no es valido; se esperaba ACTIVO o INACTIVO',
            p_tlv_estado
            USING ERRCODE = '22023';
    END IF;

    IF p_fk_tlv_jornada IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM academico_test.TLISTA_VALOR
             WHERE PK_LISTA_VALOR = p_fk_tlv_jornada
               AND ACTIVE         = TRUE
          )
    THEN
        RAISE EXCEPTION 'jornada/TLV (%) no existe o no esta activa en TLISTA_VALOR',
            p_fk_tlv_jornada
            USING ERRCODE = '23503';
    END IF;

    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante, format('Actualización de la asignación de sede/rol %s', p_pk_sede_usuario));

    WITH current_row AS (
        SELECT FK_TLV_JORNADA, ORDEN, TLV_ESTADO, PREDETERMINADO
          FROM academico_test.TSEDE_USUARIO
         WHERE PK_TSEDE_USUARIO = p_pk_sede_usuario
    ),
    cambios AS (
        SELECT
            (p_fk_tlv_jornada IS NOT NULL AND p_fk_tlv_jornada IS DISTINCT FROM current_row.FK_TLV_JORNADA) AS chg_jornada,
            (p_orden          IS NOT NULL AND p_orden          IS DISTINCT FROM current_row.ORDEN)          AS chg_orden,
            (p_tlv_estado     IS NOT NULL AND p_tlv_estado     IS DISTINCT FROM current_row.TLV_ESTADO)     AS chg_estado,
            (p_predeterminado IS NOT NULL AND p_predeterminado IS DISTINCT FROM current_row.PREDETERMINADO) AS chg_predeterminado
        FROM current_row
    )
    UPDATE academico_test.TSEDE_USUARIO t
       SET FK_TLV_JORNADA = COALESCE(p_fk_tlv_jornada, t.FK_TLV_JORNADA),
           ORDEN          = COALESCE(p_orden,          t.ORDEN),
           TLV_ESTADO     = COALESCE(p_tlv_estado,     t.TLV_ESTADO),
           PREDETERMINADO = COALESCE(p_predeterminado, t.PREDETERMINADO),
           MODIFIED_BY = CASE
                            WHEN (SELECT c.chg_jornada OR c.chg_orden OR c.chg_estado OR c.chg_predeterminado
                                    FROM cambios c)
                            THEN p_pk_usuario_solicitante::VARCHAR
                            ELSE t.MODIFIED_BY
                          END,
           MODIFIED_AT = CASE
                            WHEN (SELECT c.chg_jornada OR c.chg_orden OR c.chg_estado OR c.chg_predeterminado
                                    FROM cambios c)
                            THEN CURRENT_TIMESTAMP
                            ELSE t.MODIFIED_AT
                          END
      FROM cambios c
     WHERE t.PK_TSEDE_USUARIO = p_pk_sede_usuario
       AND t.ACTIVE           = TRUE;

    RETURN p_pk_sede_usuario;
END;
$$;
