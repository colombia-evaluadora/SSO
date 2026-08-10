-- ===========================================================================
-- V40 — Modulo de Area (TAREA) / Asignatura (TASIGNATURA) / Enfasis (TENFASIS).
-- TAREA_ASIGNATURA; la asignatura cuelga del area y opcionalmente de un enfasis
-- (especialidad creada al vuelo, ligada al establecimiento, con
-- FK_TESPECIALIDAD = 7 "Otro"). El campo del front "abreviacion" de la
-- asignatura es su CODIGO.
-- ===========================================================================

SET search_path TO academico_test, public;

-- ----- AREA (TAREA) --------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_area_crear(
    p_fk_periodo          BIGINT,
    p_fk_area_asignatura  BIGINT,
    p_nombre_interno      VARCHAR(130),
    p_abreviacion         VARCHAR(30),
    p_codigo              VARCHAR(30) DEFAULT NULL,
    p_orden_reportes      NUMERIC     DEFAULT 0,
    p_pk_usuario_solicitante BIGINT   DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    IF p_fk_periodo IS NULL OR p_fk_area_asignatura IS NULL
       OR NULLIF(TRIM(p_nombre_interno),'') IS NULL OR NULLIF(TRIM(p_abreviacion),'') IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios del area' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TAREA_ASIGNATURA
         WHERE PK_TAREA_ASIGNATURA = p_fk_area_asignatura AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El area general % no existe o esta inactiva', p_fk_area_asignatura USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TAREA a
         WHERE a.FK_TPERIODO_ACADEMICO = p_fk_periodo AND a.ACTIVE = TRUE
           AND UPPER(TRIM(a.NOMBRE)) = UPPER(TRIM(p_nombre_interno))
    ) THEN
        RAISE EXCEPTION 'Ya existe un area con el nombre % en este periodo academico', p_nombre_interno
            USING ERRCODE = '23505';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TAREA a
         WHERE a.FK_TPERIODO_ACADEMICO = p_fk_periodo AND a.ACTIVE = TRUE
           AND UPPER(TRIM(a.CODIGO)) = UPPER(TRIM(COALESCE(p_codigo, p_abreviacion)))
    ) THEN
        RAISE EXCEPTION 'Ya existe un area con el codigo % en este periodo academico',
            COALESCE(p_codigo, p_abreviacion) USING ERRCODE = '23505';
    END IF;
    INSERT INTO academico_test.TAREA
        (CODIGO, NOMBRE, FK_TPERIODO_ACADEMICO, FK_TAREA_ASIGNATURA, ORDEN_REPORTE, CREATED_BY)
    VALUES (COALESCE(p_codigo, p_abreviacion), p_nombre_interno, p_fk_periodo,
            p_fk_area_asignatura, COALESCE(p_orden_reportes, 0), v_audit)
    RETURNING PK_TAREA INTO v_id;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_area_actualizar(
    p_pk                  BIGINT,
    p_fk_area_asignatura  BIGINT DEFAULT NULL,
    p_nombre_interno      VARCHAR(130) DEFAULT NULL,
    p_abreviacion         VARCHAR(30) DEFAULT NULL,
    p_orden_reportes      NUMERIC DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    r academico_test.TAREA;
    v_nombre VARCHAR(130); v_abrev VARCHAR(30);
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    SELECT * INTO r FROM academico_test.TAREA WHERE PK_TAREA = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN RAISE EXCEPTION 'No existe un area activa con PK %', p_pk USING ERRCODE = 'P0002'; END IF;
    IF p_nombre_interno IS NOT NULL AND NULLIF(TRIM(p_nombre_interno),'') IS NULL THEN
        RAISE EXCEPTION 'El nombre del area no puede ser vacio' USING ERRCODE = '22023';
    END IF;
    IF p_abreviacion IS NOT NULL AND NULLIF(TRIM(p_abreviacion),'') IS NULL THEN
        RAISE EXCEPTION 'El codigo del area no puede ser vacio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_area_asignatura IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TAREA_ASIGNATURA
         WHERE PK_TAREA_ASIGNATURA = p_fk_area_asignatura AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'El area general % no existe o esta inactiva', p_fk_area_asignatura USING ERRCODE = '23503';
    END IF;
    v_nombre := COALESCE(p_nombre_interno, r.NOMBRE);
    v_abrev  := COALESCE(p_abreviacion, r.CODIGO);
    IF EXISTS (
        SELECT 1 FROM academico_test.TAREA a
         WHERE a.FK_TPERIODO_ACADEMICO = r.FK_TPERIODO_ACADEMICO AND a.ACTIVE = TRUE
           AND a.PK_TAREA <> p_pk AND UPPER(TRIM(a.NOMBRE)) = UPPER(TRIM(v_nombre))
    ) THEN
        RAISE EXCEPTION 'Ya existe un area con el nombre % en este periodo academico', v_nombre
            USING ERRCODE = '23505';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TAREA a
         WHERE a.FK_TPERIODO_ACADEMICO = r.FK_TPERIODO_ACADEMICO AND a.ACTIVE = TRUE
           AND a.PK_TAREA <> p_pk AND UPPER(TRIM(a.CODIGO)) = UPPER(TRIM(v_abrev))
    ) THEN
        RAISE EXCEPTION 'Ya existe un area con el codigo % en este periodo academico', v_abrev
            USING ERRCODE = '23505';
    END IF;
    UPDATE academico_test.TAREA SET
        FK_TAREA_ASIGNATURA = COALESCE(p_fk_area_asignatura, FK_TAREA_ASIGNATURA),
        NOMBRE = v_nombre,
        CODIGO = v_abrev,
        ORDEN_REPORTE = COALESCE(p_orden_reportes, ORDEN_REPORTE),
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TAREA = p_pk;
    RETURN p_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_area_soft_delete(p_pk BIGINT, p_pk_usuario_solicitante BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    -- No se puede eliminar un area con asignaturas activas.
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA WHERE FK_TAREA = p_pk AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el area %: tiene asignaturas asociadas', p_pk USING ERRCODE = '23503';
    END IF;
    UPDATE academico_test.TAREA SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TAREA = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN RAISE EXCEPTION 'No existe un area activa con PK %', p_pk USING ERRCODE = 'P0002'; END IF;
    RETURN p_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_area_listar(
    p_fk_periodo BIGINT, p_nombre_interno TEXT DEFAULT NULL,
    p_page_index INT DEFAULT 0, p_page_size INT DEFAULT 10
)
RETURNS TABLE (id BIGINT, codigo VARCHAR, nombre_interno VARCHAR,
               area_general_id BIGINT, orden_reportes NUMERIC, total_count BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT a.PK_TAREA, a.CODIGO, a.NOMBRE, a.FK_TAREA_ASIGNATURA, a.ORDEN_REPORTE,
           count(*) OVER()::BIGINT
      FROM academico_test.TAREA a
     WHERE a.FK_TPERIODO_ACADEMICO = p_fk_periodo AND a.ACTIVE = TRUE
       AND (NULLIF(TRIM(p_nombre_interno),'') IS NULL OR a.NOMBRE ILIKE '%' || p_nombre_interno || '%')
     ORDER BY a.ORDEN_REPORTE, a.NOMBRE
     LIMIT NULLIF(p_page_size, 0)
    OFFSET COALESCE(p_page_index, 0) * COALESCE(NULLIF(p_page_size, 0), 0);
$$;

-- ----- ENFASIS (TENFASIS) — resolver-o-crear por nombre en establecimiento --
-- Devuelve el PK_TENFASIS (existente o recien creado). El enfasis creado al
-- vuelo lleva la especialidad "Otro".
CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_resolver(
    p_fk_establecimiento BIGINT,
    p_nombre             VARCHAR(130),
    p_codigo             VARCHAR(30) DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_id BIGINT;
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    -- Especialidad "Otro" para enfasis creados al vuelo.
    c_especialidad_otro CONSTANT BIGINT := 7;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    SELECT PK_TENFASIS INTO v_id FROM academico_test.TENFASIS
     WHERE FK_TESTABLECIMIENTO = p_fk_establecimiento AND ACTIVE = TRUE
       AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(p_nombre));
    IF v_id IS NULL THEN
        INSERT INTO academico_test.TENFASIS (CODIGO, NOMBRE, FK_TESPECIALIDAD, FK_TESTABLECIMIENTO, CREATED_BY)
        VALUES (COALESCE(p_codigo, LEFT(p_nombre, 30)), p_nombre, c_especialidad_otro, p_fk_establecimiento, v_audit)
        RETURNING PK_TENFASIS INTO v_id;
    END IF;
    RETURN v_id;
END;
$$;

-- ----- ASIGNATURA (TASIGNATURA) — "abreviacion" del front = CODIGO ----------
CREATE OR REPLACE FUNCTION academico_test.fn_subject_crear(
    p_fk_area             BIGINT,
    p_fk_area_asignatura  BIGINT,
    p_nombre_interno      VARCHAR(130),
    p_abreviacion         VARCHAR(30),               -- va a CODIGO
    p_fk_enfasis          BIGINT      DEFAULT NULL,
    p_color               VARCHAR(10) DEFAULT NULL,
    p_orden_reportes      NUMERIC     DEFAULT 0,
    p_pk_usuario_solicitante BIGINT   DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_est BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    IF p_fk_area IS NULL OR NULLIF(TRIM(p_nombre_interno),'') IS NULL
       OR NULLIF(TRIM(p_abreviacion),'') IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios de la asignatura' USING ERRCODE = '22023';
    END IF;
    -- Establecimiento del area (via periodo -> sede). Valida que el area exista.
    SELECT s.FK_TESTABLECIMIENTO INTO v_est
      FROM academico_test.TAREA a
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = a.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE a.PK_TAREA = p_fk_area AND a.ACTIVE = TRUE;
    IF v_est IS NULL THEN
        RAISE EXCEPTION 'El area % no existe o esta inactiva', p_fk_area USING ERRCODE = '23503';
    END IF;
    IF p_fk_area_asignatura IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TAREA_ASIGNATURA
         WHERE PK_TAREA_ASIGNATURA = p_fk_area_asignatura AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'La asignatura general % no existe o esta inactiva', p_fk_area_asignatura USING ERRCODE = '23503';
    END IF;
    IF p_color IS NOT NULL AND p_color !~ '^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$' THEN
        RAISE EXCEPTION 'El color (%) debe ser un HEX valido, p.ej. #FFAA00', p_color USING ERRCODE = '22023';
    END IF;
    -- Especialidad (opcional): existe, activa y del mismo establecimiento.
    IF p_fk_enfasis IS NOT NULL THEN
        PERFORM 1 FROM academico_test.TENFASIS
         WHERE PK_TENFASIS = p_fk_enfasis AND ACTIVE = TRUE AND FK_TESTABLECIMIENTO = v_est;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'La especialidad % no existe, esta inactiva o pertenece a otro establecimiento', p_fk_enfasis
                USING ERRCODE = '22023';
        END IF;
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA s
         WHERE s.FK_TAREA = p_fk_area AND s.ACTIVE = TRUE
           AND UPPER(TRIM(s.NOMBRE)) = UPPER(TRIM(p_nombre_interno))
    ) THEN
        RAISE EXCEPTION 'Ya existe una asignatura con el nombre % en esta area', p_nombre_interno
            USING ERRCODE = '23505';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA s
         WHERE s.FK_TAREA = p_fk_area AND s.ACTIVE = TRUE
           AND UPPER(TRIM(s.CODIGO)) = UPPER(TRIM(p_abreviacion))
    ) THEN
        RAISE EXCEPTION 'Ya existe una asignatura con la abreviacion % en esta area', p_abreviacion
            USING ERRCODE = '23505';
    END IF;
    INSERT INTO academico_test.TASIGNATURA
        (CODIGO, NOMBRE, FK_TAREA, FK_TAREA_ASIGNATURA, FK_TENFASIS, COLOR, ORDEN_REPORTE, CREATED_BY)
    VALUES (p_abreviacion, p_nombre_interno, p_fk_area, p_fk_area_asignatura, p_fk_enfasis,
            p_color, COALESCE(p_orden_reportes, 0), v_audit)
    RETURNING PK_TASIGNATURA INTO v_id;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_subject_actualizar(
    p_pk                  BIGINT,
    p_fk_area_asignatura  BIGINT      DEFAULT NULL,
    p_nombre_interno      VARCHAR(130) DEFAULT NULL,
    p_abreviacion         VARCHAR(30) DEFAULT NULL,
    p_fk_enfasis          BIGINT      DEFAULT NULL,
    p_color               VARCHAR(10) DEFAULT NULL,
    p_orden_reportes      NUMERIC     DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT   DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    r academico_test.TASIGNATURA;
    v_nombre VARCHAR(130); v_codigo VARCHAR(30); v_enfasis BIGINT; v_est BIGINT;
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    SELECT * INTO r FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN RAISE EXCEPTION 'No existe una asignatura activa con PK %', p_pk USING ERRCODE = 'P0002'; END IF;
    IF p_nombre_interno IS NOT NULL AND NULLIF(TRIM(p_nombre_interno),'') IS NULL THEN
        RAISE EXCEPTION 'El nombre de la asignatura no puede ser vacio' USING ERRCODE = '22023';
    END IF;
    IF p_abreviacion IS NOT NULL AND NULLIF(TRIM(p_abreviacion),'') IS NULL THEN
        RAISE EXCEPTION 'La abreviacion de la asignatura no puede ser vacia' USING ERRCODE = '22023';
    END IF;
    IF p_fk_area_asignatura IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TAREA_ASIGNATURA
         WHERE PK_TAREA_ASIGNATURA = p_fk_area_asignatura AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'La asignatura general % no existe o esta inactiva', p_fk_area_asignatura USING ERRCODE = '23503';
    END IF;
    IF p_color IS NOT NULL AND p_color !~ '^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$' THEN
        RAISE EXCEPTION 'El color (%) debe ser un HEX valido, p.ej. #FFAA00', p_color USING ERRCODE = '22023';
    END IF;
    v_nombre  := COALESCE(p_nombre_interno, r.NOMBRE);
    v_codigo  := COALESCE(p_abreviacion, r.CODIGO);
    v_enfasis := COALESCE(p_fk_enfasis, r.FK_TENFASIS);
    -- Especialidad (si viene o ya existe): valida contra el establecimiento del area.
    IF p_fk_enfasis IS NOT NULL THEN
        SELECT s.FK_TESTABLECIMIENTO INTO v_est
          FROM academico_test.TAREA a
          JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = a.FK_TPERIODO_ACADEMICO
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
         WHERE a.PK_TAREA = r.FK_TAREA;
        PERFORM 1 FROM academico_test.TENFASIS
         WHERE PK_TENFASIS = p_fk_enfasis AND ACTIVE = TRUE AND FK_TESTABLECIMIENTO = v_est;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'La especialidad % no existe, esta inactiva o pertenece a otro establecimiento', p_fk_enfasis
                USING ERRCODE = '22023';
        END IF;
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA s
         WHERE s.FK_TAREA = r.FK_TAREA AND s.ACTIVE = TRUE AND s.PK_TASIGNATURA <> p_pk
           AND UPPER(TRIM(s.NOMBRE)) = UPPER(TRIM(v_nombre))
    ) THEN
        RAISE EXCEPTION 'Ya existe una asignatura con el nombre % en esta area', v_nombre
            USING ERRCODE = '23505';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA s
         WHERE s.FK_TAREA = r.FK_TAREA AND s.ACTIVE = TRUE AND s.PK_TASIGNATURA <> p_pk
           AND UPPER(TRIM(s.CODIGO)) = UPPER(TRIM(v_codigo))
    ) THEN
        RAISE EXCEPTION 'Ya existe una asignatura con la abreviacion % en esta area', v_codigo
            USING ERRCODE = '23505';
    END IF;
    UPDATE academico_test.TASIGNATURA SET
        FK_TAREA_ASIGNATURA = COALESCE(p_fk_area_asignatura, FK_TAREA_ASIGNATURA),
        NOMBRE = v_nombre,
        CODIGO = v_codigo,
        FK_TENFASIS = v_enfasis,
        COLOR = COALESCE(p_color, COLOR),
        ORDEN_REPORTE = COALESCE(p_orden_reportes, ORDEN_REPORTE),
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TASIGNATURA = p_pk;
    RETURN p_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_subject_soft_delete(p_pk BIGINT, p_pk_usuario_solicitante BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    -- Bloqueo por dependencias (solo filas activas).
    IF EXISTS (
        SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
         WHERE da.FK_TASIGNATURA = p_pk AND da.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar la asignatura %: existen asignaciones docente asociadas', p_pk
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.THORARIO h
         WHERE h.FK_TASIGNATURA = p_pk AND h.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar la asignatura %: existen horarios asociados', p_pk
            USING ERRCODE = '23503';
    END IF;
    UPDATE academico_test.TASIGNATURA SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TASIGNATURA = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN RAISE EXCEPTION 'No existe una asignatura activa con PK %', p_pk USING ERRCODE = 'P0002'; END IF;
    RETURN p_pk;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_subject_listar(p_fk_area BIGINT)
RETURNS TABLE (id BIGINT, abreviacion VARCHAR, nombre_interno VARCHAR,
               asignatura_general_id BIGINT, enfasis_id BIGINT, color VARCHAR, orden_reportes NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT s.PK_TASIGNATURA, s.CODIGO, s.NOMBRE, s.FK_TAREA_ASIGNATURA, s.FK_TENFASIS,
           s.COLOR, s.ORDEN_REPORTE
      FROM academico_test.TASIGNATURA s
     WHERE s.FK_TAREA = p_fk_area AND s.ACTIVE = TRUE
     ORDER BY s.ORDEN_REPORTE;
$$;

-- ----- CATALOGOS PARA SELECTS ----------------------------------------------
-- Areas/asignaturas generales (TAREA_ASIGNATURA) para el select de "area general".
CREATE OR REPLACE FUNCTION academico_test.fn_area_asignatura_listar()
RETURNS TABLE (id BIGINT, nombre VARCHAR, especialidad_id BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT PK_TAREA_ASIGNATURA, NOMBRE, FK_TESPECIALIDAD
      FROM academico_test.TAREA_ASIGNATURA
     WHERE ACTIVE = TRUE
     ORDER BY NOMBRE;
$$;

-- Especialidades (catalogo global) + enfasis del establecimiento, en una sola
-- lista con un campo 'origen' para distinguirlos.
CREATE OR REPLACE FUNCTION academico_test.fn_especialidad_enfasis_listar(p_fk_establecimiento BIGINT)
RETURNS TABLE (id BIGINT, nombre VARCHAR, codigo VARCHAR, origen TEXT)
LANGUAGE sql STABLE AS $$
    SELECT e.PK_ESPECIALIDAD, e.NOMBRE, e.CODIGO, 'ESPECIALIDAD'
      FROM academico_test.TESPECIALIDAD e
     WHERE e.ACTIVE = TRUE
    UNION ALL
    SELECT en.PK_TENFASIS, en.NOMBRE, en.CODIGO, 'ENFASIS'
      FROM academico_test.TENFASIS en
     WHERE en.ACTIVE = TRUE AND en.FK_TESTABLECIMIENTO = p_fk_establecimiento
     ORDER BY 4, 2;
$$;

-- ----- ASIGNATURAS EN LOTE (set completo del area) --------------------------
-- p_asignaturas jsonb = set COMPLETO de asignaturas del area, en el shape del
-- front: [{nombreInterno, abreviacion, asignaturaGeneral, especialidad?, color?,
-- ordenReportes?}]. Semantica de REEMPLAZO: da de baja las que ya no estan
-- (por nombre) y hace upsert por nombre de las presentes. `asignaturaGeneral` y
-- `especialidad` llegan como NOMBRE y se resuelven a id (la especialidad se
-- resuelve-o-crea como enfasis del establecimiento).
CREATE OR REPLACE FUNCTION academico_test.fn_subject_guardar_bulk(
    p_fk_area             BIGINT,
    p_asignaturas         jsonb,
    p_pk_usuario_solicitante BIGINT
)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_est BIGINT; v_count INT := 0; it jsonb;
    v_id BIGINT; v_nombre VARCHAR(130); v_codigo VARCHAR(30);
    v_aa BIGINT; v_enf BIGINT; v_color VARCHAR(10); v_orden NUMERIC;
    v_aa_name TEXT; v_enf_name TEXT;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    -- Establecimiento del area (valida que el area exista/activa).
    SELECT s.FK_TESTABLECIMIENTO INTO v_est
      FROM academico_test.TAREA a
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = a.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE a.PK_TAREA = p_fk_area AND a.ACTIVE = TRUE;
    IF v_est IS NULL THEN
        RAISE EXCEPTION 'El area % no existe o esta inactiva', p_fk_area USING ERRCODE = '23503';
    END IF;

    -- Reemplazo: baja logica de las asignaturas del area que NO vienen en el set.
    UPDATE academico_test.TASIGNATURA
       SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE FK_TAREA = p_fk_area AND ACTIVE = TRUE
       AND UPPER(TRIM(NOMBRE)) NOT IN (
           SELECT UPPER(TRIM(e->>'nombreInterno'))
             FROM jsonb_array_elements(COALESCE(p_asignaturas, '[]'::jsonb)) e
            WHERE NULLIF(TRIM(e->>'nombreInterno'),'') IS NOT NULL
       );

    FOR it IN SELECT * FROM jsonb_array_elements(COALESCE(p_asignaturas, '[]'::jsonb))
    LOOP
        v_nombre   := it->>'nombreInterno';
        v_codigo   := it->>'abreviacion';
        v_color    := NULLIF(it->>'color','');
        v_orden    := COALESCE(NULLIF(it->>'ordenReportes','')::NUMERIC, 0);
        v_aa_name  := NULLIF(TRIM(it->>'asignaturaGeneral'),'');
        v_enf_name := NULLIF(TRIM(it->>'especialidad'),'');

        IF NULLIF(TRIM(v_nombre),'') IS NULL OR NULLIF(TRIM(v_codigo),'') IS NULL THEN
            RAISE EXCEPTION 'Faltan campos obligatorios de la asignatura' USING ERRCODE = '22023';
        END IF;
        IF v_color IS NOT NULL AND v_color !~ '^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$' THEN
            RAISE EXCEPTION 'El color (%) debe ser un HEX valido, p.ej. #FFAA00', v_color USING ERRCODE = '22023';
        END IF;
        -- Asignatura general (nombre -> id de TAREA_ASIGNATURA).
        v_aa := NULL;
        IF v_aa_name IS NOT NULL THEN
            SELECT PK_TAREA_ASIGNATURA INTO v_aa FROM academico_test.TAREA_ASIGNATURA
             WHERE ACTIVE = TRUE AND UPPER(TRIM(NOMBRE)) = UPPER(v_aa_name) LIMIT 1;
            IF v_aa IS NULL THEN
                RAISE EXCEPTION 'La asignatura general "%" no existe', v_aa_name USING ERRCODE = '23503';
            END IF;
        END IF;
        -- Especialidad (nombre -> enfasis del establecimiento, resolver-o-crear).
        v_enf := NULL;
        IF v_enf_name IS NOT NULL THEN
            v_enf := academico_test.fn_enfasis_resolver(v_est, v_enf_name, NULL, p_pk_usuario_solicitante);
        END IF;

        -- Match por nombre dentro del area (upsert).
        SELECT PK_TASIGNATURA INTO v_id FROM academico_test.TASIGNATURA
         WHERE FK_TAREA = p_fk_area AND ACTIVE = TRUE
           AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(v_nombre)) LIMIT 1;
        -- Codigo unico en el area (excluyendo la fila que se va a actualizar).
        IF EXISTS (
            SELECT 1 FROM academico_test.TASIGNATURA s
             WHERE s.FK_TAREA = p_fk_area AND s.ACTIVE = TRUE
               AND s.PK_TASIGNATURA <> COALESCE(v_id, -1)
               AND UPPER(TRIM(s.CODIGO)) = UPPER(TRIM(v_codigo))
        ) THEN
            RAISE EXCEPTION 'Ya existe una asignatura con la abreviacion % en esta area', v_codigo USING ERRCODE = '23505';
        END IF;

        IF v_id IS NULL THEN
            INSERT INTO academico_test.TASIGNATURA
                (CODIGO, NOMBRE, FK_TAREA, FK_TAREA_ASIGNATURA, FK_TENFASIS, COLOR, ORDEN_REPORTE, CREATED_BY)
            VALUES (v_codigo, v_nombre, p_fk_area, v_aa, v_enf, v_color, v_orden, v_audit);
        ELSE
            UPDATE academico_test.TASIGNATURA SET
                CODIGO = v_codigo,
                FK_TAREA_ASIGNATURA = v_aa,
                FK_TENFASIS = v_enf,
                COLOR = v_color,
                ORDEN_REPORTE = v_orden,
                MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE PK_TASIGNATURA = v_id;
        END IF;
        v_count := v_count + 1;
    END LOOP;
    RETURN v_count;
END;
$$;

-- Borrado multiple de areas: intenta cada id; salta las bloqueadas.
-- Devuelve una fila por id: eliminado=TRUE, o FALSE con error_code (SQLSTATE)
-- y error_mensaje. Cada id en su subtransaccion; un fallo no revierte al resto.
DROP FUNCTION IF EXISTS academico_test.fn_area_bulk_delete(BIGINT[], BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_area_bulk_delete(
    p_ids BIGINT[], p_pk_usuario_solicitante BIGINT
)
RETURNS TABLE (id BIGINT, eliminado BOOLEAN, error_code TEXT, error_mensaje TEXT)
LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_state TEXT; v_msg TEXT;
BEGIN
    IF NOT academico_test.fn_es_super_admin(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    IF p_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_ids LOOP
        BEGIN
            PERFORM academico_test.fn_area_soft_delete(v_id, p_pk_usuario_solicitante);
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
