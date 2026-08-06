-- ===========================================================================
-- V43 — Modulo de Grado (TGRADO) y Grupo (TGRUPO). Convencion de funciones
-- (ver V37). TGRADO.NOMBRE = nombre; TGRADO.CODIGO = grado. TIENE_GRADO_SIGUIENTE
-- se deriva de si FK_TLV_GRADO_SIGUIENTE es NULL. TGRUPO.NOMBRE = campo "Grupo";
-- la jornada del grupo sale del periodo del grado (no la manda el usuario).
-- ===========================================================================

SET search_path TO academico_test, public;

-- ----- GRADO ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_grado_crear(
    p_fk_periodo          BIGINT,
    p_fk_nivel            BIGINT,
    p_nombre              VARCHAR(130),
    p_grado               VARCHAR(30),      -- CODIGO
    p_fk_grado_siguiente  BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    IF p_fk_periodo IS NULL OR p_fk_nivel IS NULL OR NULLIF(TRIM(p_nombre),'') IS NULL
       OR NULLIF(TRIM(p_grado),'') IS NULL THEN
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
           AND UPPER(TRIM(CODIGO)) = UPPER(TRIM(p_grado))
    ) THEN
        RAISE EXCEPTION 'Ya existe un grado con el codigo % en este periodo', p_grado USING ERRCODE = '23505';
    END IF;
    INSERT INTO academico_test.TGRADO
        (CODIGO, NOMBRE, FK_TPERIODO_ACADEMICO, FK_TNIVEL_ENSENANZA, FK_TLV_GRADO_SIGUIENTE,
         TIENE_GRADO_SIGUIENTE, CREATED_BY)
    VALUES (p_grado, p_nombre, p_fk_periodo, p_fk_nivel, p_fk_grado_siguiente,
            CASE WHEN p_fk_grado_siguiente IS NULL THEN 'N' ELSE 'S' END::bool_sn, v_audit)
    RETURNING PK_TGRADO INTO v_id;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grado_actualizar(
    p_pk                  BIGINT,
    p_fk_nivel            BIGINT DEFAULT NULL,
    p_nombre              VARCHAR(130) DEFAULT NULL,
    p_grado               VARCHAR(30) DEFAULT NULL,
    p_fk_grado_siguiente  BIGINT DEFAULT NULL,
    p_tiene_grado_siguiente BOOLEAN DEFAULT NULL,  -- para poder poner FK en NULL explicito
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    r academico_test.TGRADO;
    v_nombre VARCHAR(130); v_codigo VARCHAR(30); v_fk_sig BIGINT;
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    SELECT * INTO r FROM academico_test.TGRADO WHERE PK_TGRADO = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN RAISE EXCEPTION 'No existe un grado activo con PK %', p_pk USING ERRCODE = 'P0002'; END IF;
    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre),'') IS NULL THEN
        RAISE EXCEPTION 'El nombre del grado no puede ser vacio' USING ERRCODE = '22023';
    END IF;
    IF p_grado IS NOT NULL AND NULLIF(TRIM(p_grado),'') IS NULL THEN
        RAISE EXCEPTION 'El codigo del grado no puede ser vacio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_nivel IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TNIVEL_ENSENANZA WHERE PK_NIVEL_ENSENANZA = p_fk_nivel AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El nivel de ensenanza % no existe o esta inactivo', p_fk_nivel USING ERRCODE = '23503';
    END IF;
    v_nombre := COALESCE(p_nombre, r.NOMBRE);
    v_codigo := COALESCE(p_grado, r.CODIGO);
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
    IF EXISTS (
        SELECT 1 FROM academico_test.TGRADO
         WHERE FK_TPERIODO_ACADEMICO = r.FK_TPERIODO_ACADEMICO AND ACTIVE = TRUE AND PK_TGRADO <> p_pk
           AND UPPER(TRIM(CODIGO)) = UPPER(TRIM(v_codigo))
    ) THEN
        RAISE EXCEPTION 'Ya existe un grado con el codigo % en este periodo', v_codigo USING ERRCODE = '23505';
    END IF;
    UPDATE academico_test.TGRADO SET
        FK_TNIVEL_ENSENANZA = COALESCE(p_fk_nivel, FK_TNIVEL_ENSENANZA),
        NOMBRE = v_nombre,
        CODIGO = v_codigo,
        FK_TLV_GRADO_SIGUIENTE = v_fk_sig,
        TIENE_GRADO_SIGUIENTE = CASE WHEN v_fk_sig IS NULL THEN 'N' ELSE 'S' END::bool_sn,
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TGRADO = p_pk;
    RETURN p_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grado_soft_delete(p_pk BIGINT, p_pk_usuario_solicitante BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    -- Bloqueo por dependencias (solo filas activas), de lo mas especifico a lo general.
    IF EXISTS (
        SELECT 1 FROM academico_test.TMATRICULA m
          JOIN academico_test.TGRUPO g ON g.PK_TGRUPO = m.FK_TGRUPO AND g.ACTIVE = TRUE
         WHERE g.FK_TGRADO = p_pk AND m.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grado %: existen estudiantes matriculados', p_pk USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.THORARIO h
          JOIN academico_test.TGRUPO g ON g.PK_TGRUPO = h.FK_TGRUPO AND g.ACTIVE = TRUE
         WHERE g.FK_TGRADO = p_pk AND h.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grado %: existen horarios configurados', p_pk USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TPLAN pl WHERE pl.FK_TGRADO = p_pk AND pl.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grado %: existe un plan de estudio asociado', p_pk USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TGRUPO g WHERE g.FK_TGRADO = p_pk AND g.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grado %: existen grupos activos', p_pk USING ERRCODE = '23503';
    END IF;
    UPDATE academico_test.TGRADO SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TGRADO = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN RAISE EXCEPTION 'No existe un grado activo con PK %', p_pk USING ERRCODE = 'P0002'; END IF;
    RETURN p_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grado_listar(p_fk_periodo BIGINT)
RETURNS TABLE (id BIGINT, nombre VARCHAR, grado VARCHAR, teaching_level_id BIGINT,
               teaching_level_name VARCHAR, grado_siguiente VARCHAR, tiene_grado_siguiente BOOLEAN)
LANGUAGE sql STABLE AS $$
    SELECT g.PK_TGRADO, g.NOMBRE, g.CODIGO, g.FK_TNIVEL_ENSENANZA, ne.NOMBRE,
           gs.VALOR, (g.TIENE_GRADO_SIGUIENTE = 'S')
      FROM academico_test.TGRADO g
      JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
      LEFT JOIN academico_test.TLISTA_VALOR gs ON gs.PK_LISTA_VALOR = g.FK_TLV_GRADO_SIGUIENTE
     WHERE g.FK_TPERIODO_ACADEMICO = p_fk_periodo AND g.ACTIVE = TRUE
     ORDER BY g.NOMBRE;
$$;

-- ----- GRUPO ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_crear(
    p_fk_grado            BIGINT,
    p_nombre              VARCHAR(130),     -- campo "Grupo"
    p_fk_modelo_pedagogico BIGINT,
    p_capacidad           NUMERIC,
    p_fk_funcionario      BIGINT DEFAULT NULL,   -- director (id)
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_jornada BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    IF p_fk_grado IS NULL OR NULLIF(TRIM(p_nombre),'') IS NULL OR p_fk_modelo_pedagogico IS NULL
       OR p_capacidad IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios del grupo' USING ERRCODE = '22023';
    END IF;
    IF p_capacidad <= 0 THEN
        RAISE EXCEPTION 'La capacidad del grupo debe ser mayor a 0' USING ERRCODE = '22023';
    END IF;
    -- Jornada desde el periodo del grado (el grado debe estar activo).
    SELECT pa.FK_TLV_JORNADA INTO v_jornada
      FROM academico_test.TGRADO g JOIN academico_test.TPERIODO_ACADEMICO pa
        ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
     WHERE g.PK_TGRADO = p_fk_grado AND g.ACTIVE = TRUE;
    IF v_jornada IS NULL THEN
        RAISE EXCEPTION 'El grado % no existe o esta inactivo', p_fk_grado USING ERRCODE = '23503';
    END IF;
    IF p_fk_funcionario IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TFUNCIONARIO WHERE PK_TFUNCIONARIO = p_fk_funcionario AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El director % no existe o no esta habilitado', p_fk_funcionario USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TGRUPO
         WHERE FK_TGRADO = p_fk_grado AND FK_TLV_JORNADA = v_jornada AND ACTIVE = TRUE
           AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(p_nombre))
    ) THEN
        RAISE EXCEPTION 'Ya existe un grupo con el nombre % en este grado y jornada', p_nombre USING ERRCODE = '23505';
    END IF;
    INSERT INTO academico_test.TGRUPO
        (NOMBRE, FK_TGRADO, FK_TLV_JORNADA, FK_TLV_MODELO_PEDAGOGICO, CAPACIDAD, FK_TFUNCIONARIO, CREATED_BY)
    VALUES (p_nombre, p_fk_grado, v_jornada, p_fk_modelo_pedagogico, p_capacidad, p_fk_funcionario, v_audit)
    RETURNING PK_TGRUPO INTO v_id;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_actualizar(
    p_pk                  BIGINT,
    p_nombre              VARCHAR(130) DEFAULT NULL,
    p_fk_modelo_pedagogico BIGINT DEFAULT NULL,
    p_capacidad           NUMERIC DEFAULT NULL,
    p_fk_funcionario      BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    r academico_test.TGRUPO; v_nombre VARCHAR(130);
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    SELECT * INTO r FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN RAISE EXCEPTION 'No existe un grupo activo con PK %', p_pk USING ERRCODE = 'P0002'; END IF;
    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre),'') IS NULL THEN
        RAISE EXCEPTION 'El nombre del grupo no puede ser vacio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_funcionario IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TFUNCIONARIO WHERE PK_TFUNCIONARIO = p_fk_funcionario AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El director % no existe o no esta habilitado', p_fk_funcionario USING ERRCODE = '23503';
    END IF;
    IF p_capacidad IS NOT NULL AND p_capacidad <= 0 THEN
        RAISE EXCEPTION 'La capacidad del grupo debe ser mayor a 0' USING ERRCODE = '22023';
    END IF;
    v_nombre := COALESCE(p_nombre, r.NOMBRE);
    IF EXISTS (
        SELECT 1 FROM academico_test.TGRUPO
         WHERE FK_TGRADO = r.FK_TGRADO AND FK_TLV_JORNADA = r.FK_TLV_JORNADA AND ACTIVE = TRUE
           AND PK_TGRUPO <> p_pk AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(v_nombre))
    ) THEN
        RAISE EXCEPTION 'Ya existe un grupo con el nombre % en este grado y jornada', v_nombre USING ERRCODE = '23505';
    END IF;
    UPDATE academico_test.TGRUPO SET
        NOMBRE = v_nombre,
        FK_TLV_MODELO_PEDAGOGICO = COALESCE(p_fk_modelo_pedagogico, FK_TLV_MODELO_PEDAGOGICO),
        CAPACIDAD = COALESCE(p_capacidad, CAPACIDAD),
        FK_TFUNCIONARIO = COALESCE(p_fk_funcionario, FK_TFUNCIONARIO),
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TGRUPO = p_pk;
    RETURN p_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_soft_delete(p_pk BIGINT, p_pk_usuario_solicitante BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    -- Bloqueo por dependencias (solo filas activas).
    IF EXISTS (
        SELECT 1 FROM academico_test.TMATRICULA m WHERE m.FK_TGRUPO = p_pk AND m.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grupo %: existen estudiantes matriculados', p_pk USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da WHERE da.FK_TGRUPO = p_pk AND da.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grupo %: existen asignaciones academicas asociadas', p_pk USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.THORARIO h WHERE h.FK_TGRUPO = p_pk AND h.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el grupo %: existen horarios configurados', p_pk USING ERRCODE = '23503';
    END IF;
    UPDATE academico_test.TGRUPO SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TGRUPO = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN RAISE EXCEPTION 'No existe un grupo activo con PK %', p_pk USING ERRCODE = 'P0002'; END IF;
    RETURN p_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_listar(p_fk_grado BIGINT)
RETURNS TABLE (id BIGINT, codigo VARCHAR, jornada VARCHAR, director_id BIGINT,
               metodologia VARCHAR, cupo NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT gr.PK_TGRUPO, gr.NOMBRE, jor.VALOR, gr.FK_TFUNCIONARIO, met.VALOR, gr.CAPACIDAD
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TLISTA_VALOR jor      ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
      LEFT JOIN academico_test.TLISTA_VALOR met ON met.PK_LISTA_VALOR = gr.FK_TLV_MODELO_PEDAGOGICO
     WHERE gr.FK_TGRADO = p_fk_grado AND gr.ACTIVE = TRUE
     ORDER BY gr.NOMBRE;
$$;
