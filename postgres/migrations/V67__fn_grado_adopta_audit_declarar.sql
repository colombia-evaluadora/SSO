-- V67 — primera adopción real de fn_audit_declarar (V66) en funciones de
-- escritura, para una prueba end-to-end del pipeline cdc-sync completo:
-- Postgres (trigger trg_audit_ctx) → cdc-capture → RabbitMQ → cdc-worker →
-- ClickHouse (auditoria.audit_log.etiqueta / app_user).
--
-- Se instrumentan solo fn_grado_crear y fn_grado_actualizar como prueba de
-- concepto — son las funciones usadas como ejemplo canónico en
-- docs/etiqueta-auditoria-cdc-analisis.md §6.1 y ya tienen datos semilla
-- reales en local ("grado Octavo", PK_TGRADO=1). Adoptar el helper en las
-- 65 funciones restantes del catálogo (docs/etiqueta-catalogo-funciones-fn.md)
-- queda como trabajo de seguimiento, no parte de esta migración.
--
-- Cambio en ambas funciones: se captura el establecimiento_id UNA vez en una
-- variable (antes se recalculaba inline solo para el gate de permisos) y se
-- reutiliza tanto para fn_periodo_gate_escritura como para
-- fn_audit_declarar — cero I/O adicional respecto a la versión anterior.

CREATE OR REPLACE FUNCTION academico_test.fn_grado_crear(
    p_fk_periodo          BIGINT,
    p_fk_nivel            BIGINT,
    p_nombre              VARCHAR(130),     -- al crear = valor del catalogo GRADOS
    p_fk_grado_siguiente  BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_id BIGINT; v_codigo VARCHAR(30);
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_establecimiento_id BIGINT := academico_test.fn_periodo_establecimiento(p_fk_periodo);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_establecimiento_id);
    IF p_fk_periodo IS NULL OR p_fk_nivel IS NULL OR NULLIF(TRIM(p_nombre),'') IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios del grado' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_ACADEMICO
         WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El periodo academico % no existe o esta inactivo', p_fk_periodo USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TNIVEL_ENSENANZA
         WHERE PK_NIVEL_ENSENANZA = p_fk_nivel AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El nivel de ensenanza % no existe o esta inactivo', p_fk_nivel USING ERRCODE = '23503';
    END IF;
    -- El codigo se DERIVA del catalogo GRADOS: p_nombre es un grado del catalogo
    -- (nombre o valor, p.ej. "octavo"/"8") y el codigo del TGRADO es su VALOR.
    SELECT VALOR INTO v_codigo
      FROM academico_test.TLISTA_VALOR
     WHERE CATEGORIA = 'GRADOS' AND ACTIVE = TRUE
       AND (UPPER(TRIM(NOMBRE)) = UPPER(TRIM(p_nombre)) OR TRIM(VALOR) = TRIM(p_nombre))
     LIMIT 1;
    IF v_codigo IS NULL THEN
        RAISE EXCEPTION 'El grado "%" no existe en el catalogo GRADOS', p_nombre USING ERRCODE = '23503';
    END IF;
    IF p_fk_grado_siguiente IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = p_fk_grado_siguiente AND ACTIVE = TRUE AND CATEGORIA = 'GRADOS'
    ) THEN
        RAISE EXCEPTION 'El grado siguiente % no es valido (debe ser de la categoria GRADOS)', p_fk_grado_siguiente
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TGRADO
         WHERE FK_TPERIODO_ACADEMICO = p_fk_periodo AND ACTIVE = TRUE
           AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(p_nombre))
    ) THEN
        RAISE EXCEPTION 'Ya existe un grado con el nombre % en este periodo', p_nombre USING ERRCODE = '23505';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TGRADO
         WHERE FK_TPERIODO_ACADEMICO = p_fk_periodo AND ACTIVE = TRUE
           AND UPPER(TRIM(CODIGO)) = UPPER(TRIM(v_codigo))
    ) THEN
        RAISE EXCEPTION 'Ya existe un grado con el codigo % en este periodo', v_codigo USING ERRCODE = '23505';
    END IF;

    -- V67: declara atribución + etiqueta antes del INSERT, misma transacción.
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Creación del grado %s', p_nombre),
        v_establecimiento_id
    );

    INSERT INTO academico_test.TGRADO
        (CODIGO, NOMBRE, FK_TPERIODO_ACADEMICO, FK_TNIVEL_ENSENANZA, FK_TLV_GRADO_SIGUIENTE,
         TIENE_GRADO_SIGUIENTE, CREATED_BY)
    VALUES (v_codigo, p_nombre, p_fk_periodo, p_fk_nivel, p_fk_grado_siguiente,
            CASE WHEN p_fk_grado_siguiente IS NULL THEN 'N' ELSE 'S' END::academico_test.bool_sn, v_audit)
    RETURNING PK_TGRADO INTO v_id;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grado_actualizar(
    p_pk                  BIGINT,
    p_fk_nivel            BIGINT DEFAULT NULL,
    p_nombre              VARCHAR(130) DEFAULT NULL,   -- editable libre tras crear
    p_fk_grado_siguiente  BIGINT DEFAULT NULL,
    p_tiene_grado_siguiente BOOLEAN DEFAULT NULL,  -- para poder poner FK en NULL explicito
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    r academico_test.TGRADO;
    v_nombre VARCHAR(130); v_fk_sig BIGINT;
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_establecimiento_id BIGINT;
BEGIN
    SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
      INTO v_establecimiento_id
      FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_pk;
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_establecimiento_id);
    SELECT * INTO r FROM academico_test.TGRADO WHERE PK_TGRADO = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN RAISE EXCEPTION 'No existe un grado activo con PK %', p_pk USING ERRCODE = 'P0002'; END IF;
    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre),'') IS NULL THEN
        RAISE EXCEPTION 'El nombre del grado no puede ser vacio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_nivel IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TNIVEL_ENSENANZA WHERE PK_NIVEL_ENSENANZA = p_fk_nivel AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El nivel de ensenanza % no existe o esta inactivo', p_fk_nivel USING ERRCODE = '23503';
    END IF;
    v_nombre := COALESCE(p_nombre, r.NOMBRE);
    -- El codigo NO se cambia en edicion (queda el derivado del catalogo al crear).
    -- Si p_tiene_grado_siguiente = FALSE, se limpia el FK; si TRUE o NULL, se
    -- usa p_fk_grado_siguiente (COALESCE con el actual cuando llega NULL).
    v_fk_sig := CASE WHEN p_tiene_grado_siguiente = FALSE THEN NULL
                     ELSE COALESCE(p_fk_grado_siguiente, r.FK_TLV_GRADO_SIGUIENTE) END;
    IF v_fk_sig IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TLISTA_VALOR
         WHERE PK_LISTA_VALOR = v_fk_sig AND ACTIVE = TRUE AND CATEGORIA = 'GRADOS'
    ) THEN
        RAISE EXCEPTION 'El grado siguiente % no es valido (debe ser de la categoria GRADOS)', v_fk_sig
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TGRADO
         WHERE FK_TPERIODO_ACADEMICO = r.FK_TPERIODO_ACADEMICO AND ACTIVE = TRUE AND PK_TGRADO <> p_pk
           AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(v_nombre))
    ) THEN
        RAISE EXCEPTION 'Ya existe un grado con el nombre % en este periodo', v_nombre USING ERRCODE = '23505';
    END IF;

    -- V67: declara atribución + etiqueta antes del UPDATE, misma transacción.
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Actualización del grado %s', v_nombre),
        v_establecimiento_id
    );

    UPDATE academico_test.TGRADO SET
        FK_TNIVEL_ENSENANZA = COALESCE(p_fk_nivel, FK_TNIVEL_ENSENANZA),
        NOMBRE = v_nombre,
        FK_TLV_GRADO_SIGUIENTE = v_fk_sig,
        TIENE_GRADO_SIGUIENTE = CASE WHEN v_fk_sig IS NULL THEN 'N' ELSE 'S' END::academico_test.bool_sn,
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TGRADO = p_pk;
    RETURN p_pk;
END;
$$;
