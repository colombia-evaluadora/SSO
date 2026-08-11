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
    p_nombre              VARCHAR(130),     -- al crear = valor del catalogo GRADOS
    p_fk_grado_siguiente  BIGINT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_id BIGINT; v_codigo VARCHAR(30);
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, academico_test.fn_periodo_establecimiento(p_fk_periodo));
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
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_pk));
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

CREATE OR REPLACE FUNCTION academico_test.fn_grado_soft_delete(p_pk BIGINT, p_pk_usuario_solicitante BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_pk));
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
    -- Cascade: el criterio de promocion override del grado (POR_DEFECTO='N') y sus
    -- obligatorias son propiedad del grado, se dan de baja con el.
    UPDATE academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE ACTIVE = TRUE AND FK_TCRITERIO_PROMOCION IN (
         SELECT PK_TCRITERIO_PROMOCION FROM academico_test.TCRITERIO_PROMOCION
          WHERE FK_TGRADO = p_pk AND ACTIVE = TRUE
     );
    UPDATE academico_test.TCRITERIO_PROMOCION SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TGRADO = p_pk AND ACTIVE = TRUE;
    UPDATE academico_test.TGRADO SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TGRADO = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN RAISE EXCEPTION 'No existe un grado activo con PK %', p_pk USING ERRCODE = 'P0002'; END IF;
    RETURN p_pk;
END;
$$;

DROP FUNCTION IF EXISTS academico_test.fn_grado_listar(BIGINT, TEXT, INT, INT);
DROP FUNCTION IF EXISTS academico_test.fn_grado_listar(BIGINT, TEXT, INT, INT, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_grado_listar(
    p_fk_periodo BIGINT,
    p_filtro     TEXT DEFAULT NULL,   -- filtro por nombre (opcional)
    p_page_index INT  DEFAULT 0,      -- 0-based
    p_page_size  INT  DEFAULT 10,     -- 0/NULL = sin paginar (todo)
    p_pk_usuario BIGINT DEFAULT NULL  -- alcance (global / establecimiento)
)
RETURNS TABLE (id BIGINT, nombre VARCHAR, grado VARCHAR, teaching_level_id BIGINT,
               teaching_level_name VARCHAR, grado_siguiente VARCHAR, grado_siguiente_name VARCHAR,
               tiene_grado_siguiente BOOLEAN, total_count BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT g.PK_TGRADO, g.NOMBRE, g.CODIGO, g.FK_TNIVEL_ENSENANZA, ne.NOMBRE,
           gs.VALOR, gs.NOMBRE, (g.TIENE_GRADO_SIGUIENTE = 'S'),
           count(*) OVER()::BIGINT AS total_count
      FROM academico_test.TGRADO g
      JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
      LEFT JOIN academico_test.TLISTA_VALOR gs ON gs.PK_LISTA_VALOR = g.FK_TLV_GRADO_SIGUIENTE
     WHERE g.FK_TPERIODO_ACADEMICO = p_fk_periodo AND g.ACTIVE = TRUE
       AND academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario, p_fk_periodo)
       AND (NULLIF(TRIM(p_filtro),'') IS NULL OR g.NOMBRE ILIKE '%' || p_filtro || '%')
     ORDER BY g.NOMBRE
     LIMIT NULLIF(p_page_size, 0)
    OFFSET COALESCE(p_page_index, 0) * COALESCE(NULLIF(p_page_size, 0), 0);
$$;

-- Un solo grado por id (mismos campos que fn_grado_listar, sin paginacion).
-- Respeta el alcance por establecimiento via fn_periodo_usuario_puede_ver.
CREATE OR REPLACE FUNCTION academico_test.fn_grado_obtener(
    p_fk_grado BIGINT, p_pk_usuario BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, nombre VARCHAR, grado VARCHAR, teaching_level_id BIGINT,
               teaching_level_name VARCHAR, grado_siguiente VARCHAR, grado_siguiente_name VARCHAR,
               tiene_grado_siguiente BOOLEAN)
LANGUAGE sql STABLE AS $$
    SELECT g.PK_TGRADO, g.NOMBRE, g.CODIGO, g.FK_TNIVEL_ENSENANZA, ne.NOMBRE,
           gs.VALOR, gs.NOMBRE, (g.TIENE_GRADO_SIGUIENTE = 'S')
      FROM academico_test.TGRADO g
      JOIN academico_test.TNIVEL_ENSENANZA ne ON ne.PK_NIVEL_ENSENANZA = g.FK_TNIVEL_ENSENANZA
      LEFT JOIN academico_test.TLISTA_VALOR gs ON gs.PK_LISTA_VALOR = g.FK_TLV_GRADO_SIGUIENTE
     WHERE g.PK_TGRADO = p_fk_grado AND g.ACTIVE = TRUE
       AND academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario, g.FK_TPERIODO_ACADEMICO);
$$;

-- ----- GRUPO ---------------------------------------------------------------
-- DROP de la firma con p_fk_rol (7 args) por si quedo aplicada; se recrea sin rol.
DROP FUNCTION IF EXISTS academico_test.fn_grupo_crear(BIGINT, VARCHAR, BIGINT, NUMERIC, BIGINT, BIGINT, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_crear(
    p_fk_grado            BIGINT,
    p_nombre              VARCHAR(130),     -- campo "Grupo"
    p_fk_modelo_pedagogico BIGINT,
    p_capacidad           NUMERIC,
    p_fk_funcionario      BIGINT DEFAULT NULL,   -- director (id)
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_jornada BIGINT; v_sede BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TGRADO g WHERE g.PK_TGRADO = p_fk_grado));
    IF p_fk_grado IS NULL OR NULLIF(TRIM(p_nombre),'') IS NULL OR p_fk_modelo_pedagogico IS NULL
       OR p_capacidad IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios del grupo' USING ERRCODE = '22023';
    END IF;
    IF p_capacidad <= 0 THEN
        RAISE EXCEPTION 'La capacidad del grupo debe ser mayor a 0' USING ERRCODE = '22023';
    END IF;
    -- Jornada y sede desde el periodo del grado (el grado debe estar activo).
    SELECT pa.FK_TLV_JORNADA, pa.FK_TSEDE INTO v_jornada, v_sede
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
    -- El director debe pertenecer a la sede del grado (via su usuario en TSEDE_USUARIO).
    IF p_fk_funcionario IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TSEDE_USUARIO su ON su.FK_TUSUARIO = f.FK_TUSUARIO
         WHERE f.PK_TFUNCIONARIO = p_fk_funcionario
           AND su.FK_TSEDE = v_sede AND su.ACTIVE = TRUE AND su.TLV_ESTADO = 'ACTIVO'
    ) THEN
        RAISE EXCEPTION 'El director % no pertenece a la sede de este grado', p_fk_funcionario USING ERRCODE = '23503';
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

-- DROP de la firma con p_fk_rol (7 args) por si quedo aplicada; se recrea sin rol.
DROP FUNCTION IF EXISTS academico_test.fn_grupo_actualizar(BIGINT, VARCHAR, BIGINT, NUMERIC, BIGINT, BIGINT, BIGINT);
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
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TGRUPO gr JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
         WHERE gr.PK_TGRUPO = p_pk));
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
    -- El director debe pertenecer a la sede del grado del grupo (via TSEDE_USUARIO).
    IF p_fk_funcionario IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TFUNCIONARIO f
          JOIN academico_test.TSEDE_USUARIO su ON su.FK_TUSUARIO = f.FK_TUSUARIO
          JOIN academico_test.TGRADO g ON g.PK_TGRADO = r.FK_TGRADO
          JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = g.FK_TPERIODO_ACADEMICO
         WHERE f.PK_TFUNCIONARIO = p_fk_funcionario
           AND su.FK_TSEDE = pa.FK_TSEDE
           AND su.ACTIVE = TRUE AND su.TLV_ESTADO = 'ACTIVO'
    ) THEN
        RAISE EXCEPTION 'El director % no pertenece a la sede de este grado', p_fk_funcionario USING ERRCODE = '23503';
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
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(g.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TGRUPO gr JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
         WHERE gr.PK_TGRUPO = p_pk));
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

DROP FUNCTION IF EXISTS academico_test.fn_grupo_listar(BIGINT, TEXT, INT, INT);
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_listar(
    p_fk_grado BIGINT, p_filtro TEXT DEFAULT NULL,
    p_page_index INT DEFAULT 0, p_page_size INT DEFAULT 10,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, codigo VARCHAR, jornada VARCHAR, jornada_name VARCHAR, director_id BIGINT,
               director_name TEXT, metodologia VARCHAR, metodologia_name VARCHAR, cupo NUMERIC, total_count BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT gr.PK_TGRUPO, gr.NOMBRE, jor.VALOR, jor.NOMBRE, gr.FK_TFUNCIONARIO,
           TRIM(regexp_replace(
               concat_ws(' ', du.PRIMER_NOMBRE, du.SEGUNDO_NOMBRE, du.PRIMER_APELLIDO, du.SEGUNDO_APELLIDO),
               '\s+', ' ', 'g')),
           met.VALOR, met.NOMBRE, gr.CAPACIDAD,
           count(*) OVER()::BIGINT
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TLISTA_VALOR jor      ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
      LEFT JOIN academico_test.TLISTA_VALOR met ON met.PK_LISTA_VALOR = gr.FK_TLV_MODELO_PEDAGOGICO
      LEFT JOIN academico_test.TFUNCIONARIO df  ON df.PK_TFUNCIONARIO = gr.FK_TFUNCIONARIO
      LEFT JOIN academico_test.TUSUARIO du      ON du.PK_TUSUARIO = df.FK_TUSUARIO
     WHERE gr.FK_TGRADO = p_fk_grado AND gr.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_filtro),'') IS NULL OR gr.NOMBRE ILIKE '%' || p_filtro || '%')
     ORDER BY gr.NOMBRE
     LIMIT NULLIF(p_page_size, 0)
    OFFSET COALESCE(p_page_index, 0) * COALESCE(NULLIF(p_page_size, 0), 0);
$$;

-- Un solo grupo por id (detalle para el formulario de edicion). Incluye el
-- modelo pedagogico y el rol del director en la sede para reconstruir el form.
DROP FUNCTION IF EXISTS academico_test.fn_grupo_obtener(BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_obtener(
    p_pk BIGINT, p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, codigo VARCHAR, jornada VARCHAR, jornada_name VARCHAR,
               director_id BIGINT, director_name TEXT, director_rol_id BIGINT,
               metodologia_id BIGINT, metodologia VARCHAR, metodologia_name VARCHAR,
               cupo NUMERIC, grado_id BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT gr.PK_TGRUPO, gr.NOMBRE, jor.VALOR, jor.NOMBRE,
           gr.FK_TFUNCIONARIO,
           TRIM(regexp_replace(
               concat_ws(' ', du.PRIMER_NOMBRE, du.SEGUNDO_NOMBRE, du.PRIMER_APELLIDO, du.SEGUNDO_APELLIDO),
               '\s+', ' ', 'g')),
           (SELECT su.FK_TROL FROM academico_test.TSEDE_USUARIO su
             JOIN academico_test.TGRADO g2 ON g2.PK_TGRADO = gr.FK_TGRADO
             JOIN academico_test.TPERIODO_ACADEMICO pa2 ON pa2.PK_TPERIODO_ACADEMICO = g2.FK_TPERIODO_ACADEMICO
            WHERE su.FK_TUSUARIO = df.FK_TUSUARIO AND su.FK_TSEDE = pa2.FK_TSEDE
              AND su.ACTIVE = TRUE AND su.TLV_ESTADO = 'ACTIVO'
            LIMIT 1),
           gr.FK_TLV_MODELO_PEDAGOGICO, met.VALOR, met.NOMBRE, gr.CAPACIDAD, gr.FK_TGRADO
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TLISTA_VALOR jor      ON jor.PK_LISTA_VALOR = gr.FK_TLV_JORNADA
      LEFT JOIN academico_test.TLISTA_VALOR met ON met.PK_LISTA_VALOR = gr.FK_TLV_MODELO_PEDAGOGICO
      LEFT JOIN academico_test.TFUNCIONARIO df  ON df.PK_TFUNCIONARIO = gr.FK_TFUNCIONARIO
      LEFT JOIN academico_test.TUSUARIO du      ON du.PK_TUSUARIO = df.FK_TUSUARIO
     WHERE gr.PK_TGRUPO = p_pk AND gr.ACTIVE = TRUE;
$$;

-- Catalogo de niveles de ensenanza (para el select de nivel del grado).
DROP FUNCTION IF EXISTS academico_test.fn_nivel_ensenanza_listar();
CREATE OR REPLACE FUNCTION academico_test.fn_nivel_ensenanza_listar(
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, codigo VARCHAR, nombre VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT PK_NIVEL_ENSENANZA, CODIGO, NOMBRE
      FROM academico_test.TNIVEL_ENSENANZA
     WHERE ACTIVE = TRUE
     ORDER BY NOMBRE;
$$;

-- Funcionarios de una sede (para el selector de director del grupo). El vinculo
-- funcionario-sede es via su usuario en TSEDE_USUARIO. Filtro opcional por
-- nombre o identificacion. DISTINCT porque un usuario puede tener varias filas
-- en TSEDE_USUARIO (por rol/jornada).
-- DROP de firmas previas (con p_fk_rol y sin p_pk_usuario) por si quedaron aplicadas.
DROP FUNCTION IF EXISTS academico_test.fn_funcionario_sede_listar(BIGINT, BIGINT, TEXT);
DROP FUNCTION IF EXISTS academico_test.fn_funcionario_sede_listar(BIGINT, TEXT);
CREATE OR REPLACE FUNCTION academico_test.fn_funcionario_sede_listar(
    p_fk_sede BIGINT, p_filtro TEXT DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, nombre TEXT, identificacion VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT DISTINCT f.PK_TFUNCIONARIO,
           TRIM(regexp_replace(
               concat_ws(' ', u.PRIMER_NOMBRE, u.SEGUNDO_NOMBRE, u.PRIMER_APELLIDO, u.SEGUNDO_APELLIDO),
               '\s+', ' ', 'g')) AS nombre,
           u.IDENTIFICACION
      FROM academico_test.TFUNCIONARIO f
      JOIN academico_test.TUSUARIO u ON u.PK_TUSUARIO = f.FK_TUSUARIO
      JOIN academico_test.TSEDE_USUARIO su ON su.FK_TUSUARIO = f.FK_TUSUARIO
     WHERE su.FK_TSEDE = p_fk_sede
       AND su.ACTIVE = TRUE AND su.TLV_ESTADO = 'ACTIVO'
       AND f.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_filtro),'') IS NULL
            OR u.PRIMER_NOMBRE   ILIKE '%' || p_filtro || '%'
            OR u.PRIMER_APELLIDO ILIKE '%' || p_filtro || '%'
            OR u.SEGUNDO_APELLIDO ILIKE '%' || p_filtro || '%'
            OR u.IDENTIFICACION  ILIKE '%' || p_filtro || '%')
     ORDER BY nombre;
$$;

-- Borrado multiple de grados: intenta cada id; salta los bloqueados.
-- Devuelve una fila por id: eliminado=TRUE, o FALSE con error_code (SQLSTATE)
-- y error_mensaje. Cada id en su subtransaccion; un fallo no revierte al resto.
DROP FUNCTION IF EXISTS academico_test.fn_grado_bulk_delete(BIGINT[], BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_grado_bulk_delete(
    p_ids BIGINT[], p_pk_usuario_solicitante BIGINT
)
RETURNS TABLE (id BIGINT, eliminado BOOLEAN, error_code TEXT, error_mensaje TEXT)
LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_state TEXT; v_msg TEXT;
BEGIN
    -- Gate grueso; el fino por establecimiento lo aplica fn_grado_soft_delete.
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, NULL);
    IF p_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_ids LOOP
        BEGIN
            PERFORM academico_test.fn_grado_soft_delete(v_id, p_pk_usuario_solicitante);
            id := v_id; eliminado := TRUE; error_code := NULL; error_mensaje := NULL;
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
            id := v_id; eliminado := FALSE; error_code := v_state; error_mensaje := v_msg;
            RETURN NEXT;
        END;
    END LOOP;
    RETURN;
END;
$$;

-- ----- CONFIG DEL GRADO (/grades/:id/config = horario + criterio de promocion) --
-- Devuelve { schedule: { entries: [...] }, promotionCriteria: {...} }.
DROP FUNCTION IF EXISTS academico_test.fn_grade_config_obtener(BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_grade_config_obtener(
    p_fk_grado BIGINT, p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v_periodo BIGINT; v_entries jsonb; v_prom jsonb; v_req jsonb; c RECORD;
BEGIN
    SELECT FK_TPERIODO_ACADEMICO INTO v_periodo FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
    -- Horario -> entries.
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
             'grupoId', h.grupo_id, 'planItemId', h.plan_item_id,
             'diaId', h.dia_id, 'bloque', h.bloque)), '[]'::jsonb)
      INTO v_entries FROM academico_test.fn_horario_listar(p_fk_grado) h;
    -- Criterio de promocion (override del grado o default del periodo).
    SELECT * INTO c FROM academico_test.fn_criterio_prom_obtener(v_periodo, p_fk_grado) LIMIT 1;
    IF c.id IS NOT NULL THEN
        SELECT COALESCE(jsonb_agg(COALESCE(a.subject_id, a.area_id)::text), '[]'::jsonb)
          INTO v_req FROM academico_test.fn_criterio_prom_asig_listar(c.id) a;
        v_prom := jsonb_build_object(
            'curriculumNode', c.curriculum_node,
            'maxFailedRecovery', c.max_failed_recovery,
            'absencePercentage', c.absence_percentage,
            'maxLeveledSubjects', c.max_leveled_subjects,
            'applyAverageApproval', (c.apply_average_approval = 'S'),
            'basePercentage', c.base_percentage,
            'minimumSubjectPercentage', c.minimum_subject_percentage,
            'maxFailedForAverage', c.max_failed_for_average,
            'requiredSubjects', v_req
        );
    END IF;
    RETURN jsonb_build_object(
        'schedule', jsonb_build_object('entries', v_entries),
        'promotionCriteria', v_prom
    );
END;
$$;

-- Guarda la config: despacha horario y/o criterio de promocion (override del grado).
CREATE OR REPLACE FUNCTION academico_test.fn_grade_config_guardar(
    p_fk_grado  BIGINT,
    p_schedule  jsonb DEFAULT NULL,
    p_promotion jsonb DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_periodo BIGINT; v_oblig jsonb;
BEGIN
    -- Horario (si viene).
    IF p_schedule IS NOT NULL AND p_schedule ? 'entries' THEN
        PERFORM academico_test.fn_horario_guardar(p_fk_grado, p_schedule->'entries', p_pk_usuario_solicitante);
    END IF;
    -- Criterio de promocion (si viene) — override por grado.
    IF p_promotion IS NOT NULL THEN
        SELECT FK_TPERIODO_ACADEMICO INTO v_periodo FROM academico_test.TGRADO WHERE PK_TGRADO = p_fk_grado;
        -- requiredSubjects (ids) -> obligatorias [{asignaturaId}].
        IF p_promotion ? 'requiredSubjects' THEN
            SELECT COALESCE(jsonb_agg(jsonb_build_object('asignaturaId', (x)::bigint)), '[]'::jsonb)
              INTO v_oblig
              FROM jsonb_array_elements_text(p_promotion->'requiredSubjects') x
             WHERE NULLIF(TRIM(x),'') IS NOT NULL;
        END IF;
        PERFORM academico_test.fn_criterio_prom_guardar(
            v_periodo, p_fk_grado,
            NULLIF(TRIM(p_promotion->>'curriculumNode'),'')::academico_test.nodo_curricular,
            NULLIF(p_promotion->>'maxFailedRecovery','')::numeric,
            NULL,  -- p_asignatura_obligatoria (no lo maneja el front)
            CASE lower(p_promotion->>'applyAverageApproval')
                 WHEN 'true' THEN 'S' WHEN 'false' THEN 'N' ELSE NULL END::academico_test.bool_sn,
            NULLIF(p_promotion->>'basePercentage','')::numeric,
            NULLIF(p_promotion->>'minimumSubjectPercentage','')::numeric,
            NULLIF(p_promotion->>'maxFailedForAverage','')::numeric,
            NULLIF(p_promotion->>'absencePercentage','')::numeric,
            NULLIF(p_promotion->>'maxLeveledSubjects','')::numeric,
            v_oblig,
            p_pk_usuario_solicitante
        );
    END IF;
    RETURN p_fk_grado;
END;
$$;
