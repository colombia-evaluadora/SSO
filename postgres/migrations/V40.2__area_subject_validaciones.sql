-- ===========================================================================
-- V40.2 -- Areas, asignaturas y enfasis: validaciones
-- ===========================================================================
-- QUE HACE: una fn_<dom>_validar_<regla> por regla (RETURNS VOID, lanza o
-- nada) para area, asignatura y enfasis, y las que componen crear/actualizar
-- y eliminar.
-- POR QUE AQUI: capa 1 del modulo (V40.2 validaciones / V40.3 nucleos /
-- V40.4 wrappers). Los endpoints siguen en V77 porque necesitan eval-col (V47).
-- DEPENDE DE: V22 (TAREA, TASIGNATURA, TENFASIS, TESPECIALIDAD y dependientes).
-- ===========================================================================

SET search_path TO academico_test, public;

-- --------------------------------------------------------------------- area

CREATE OR REPLACE FUNCTION academico_test.fn_area_validar_existe_activa(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TAREA WHERE PK_TAREA = p_pk AND ACTIVE = TRUE) THEN
        SELECT NOMBRE INTO v_nombre FROM academico_test.TAREA WHERE PK_TAREA = p_pk;
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El area % existe pero esta inactiva', v_nombre USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe un area activa con el PK indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_area_validar_campos(
    p_fk_periodo BIGINT, p_fk_area_asignatura BIGINT, p_nombre VARCHAR, p_abreviacion VARCHAR
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_fk_periodo IS NULL OR p_fk_area_asignatura IS NULL
       OR NULLIF(TRIM(p_nombre),'') IS NULL OR NULLIF(TRIM(p_abreviacion),'') IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios del area' USING ERRCODE = '22023';
    END IF;
END;
$$;

-- En actualizar NULL = conservar el valor; solo se rechaza el texto vacio.
CREATE OR REPLACE FUNCTION academico_test.fn_area_validar_nombre_no_vacio(p_nombre VARCHAR)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre),'') IS NULL THEN
        RAISE EXCEPTION 'El nombre del area no puede ser vacio' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_area_validar_codigo_no_vacio(p_abreviacion VARCHAR)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_abreviacion IS NOT NULL AND NULLIF(TRIM(p_abreviacion),'') IS NULL THEN
        RAISE EXCEPTION 'El codigo del area no puede ser vacio' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_area_validar_area_general(p_fk_area_asignatura BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    IF p_fk_area_asignatura IS NULL THEN RETURN; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TAREA_ASIGNATURA
         WHERE PK_TAREA_ASIGNATURA = p_fk_area_asignatura AND ACTIVE = TRUE
    ) THEN
        SELECT NOMBRE INTO v_nombre FROM academico_test.TAREA_ASIGNATURA
         WHERE PK_TAREA_ASIGNATURA = p_fk_area_asignatura;
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El area general % ya existe pero esta inactiva', v_nombre USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El area general seleccionada no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
END;
$$;

-- p_campo: NOMBRE | CODIGO. Unico entre las areas activas del periodo academico.
CREATE OR REPLACE FUNCTION academico_test.fn_area_validar_unico(
    p_fk_periodo BIGINT, p_campo TEXT, p_valor VARCHAR, p_pk_excluir BIGINT DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_valor IS NULL THEN RETURN; END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TAREA a
         WHERE a.FK_TPERIODO_ACADEMICO = p_fk_periodo AND a.ACTIVE = TRUE
           AND a.PK_TAREA <> COALESCE(p_pk_excluir, -1)
           AND UPPER(TRIM(CASE p_campo WHEN 'NOMBRE' THEN a.NOMBRE ELSE a.CODIGO END)) = UPPER(TRIM(p_valor))
    ) THEN
        RAISE EXCEPTION 'Ya existe un area con % % en este periodo academico',
            CASE p_campo WHEN 'NOMBRE' THEN 'el nombre' ELSE 'la abreviacion' END, p_valor
            USING ERRCODE = '23505';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_area_validar_sin_asignaturas(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TASIGNATURA WHERE FK_TAREA = p_pk AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se puede eliminar el area %: tiene asignaturas asociadas',
            COALESCE((SELECT NOMBRE FROM academico_test.TAREA WHERE PK_TAREA = p_pk), p_pk::text)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_area_validar_sin_calificaciones(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TAREA_NOTA tn WHERE tn.FK_TAREA = p_pk AND tn.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se puede eliminar el area %: existen calificaciones registradas',
            COALESCE((SELECT NOMBRE FROM academico_test.TAREA WHERE PK_TAREA = p_pk), p_pk::text)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_area_validar_sin_criterio_promocion(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA cpo
         WHERE cpo.FK_TAREA = p_pk AND cpo.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el area %: esta marcada como obligatoria en un criterio de promocion',
            COALESCE((SELECT NOMBRE FROM academico_test.TAREA WHERE PK_TAREA = p_pk), p_pk::text)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

-- El orden es contrato: area general, nombre unico, abreviacion unica.
CREATE OR REPLACE FUNCTION academico_test.fn_area_validar(
    p_fk_periodo BIGINT, p_fk_area_asignatura BIGINT, p_nombre VARCHAR, p_abreviacion VARCHAR,
    p_pk_excluir BIGINT DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM academico_test.fn_area_validar_area_general(p_fk_area_asignatura);
    PERFORM academico_test.fn_area_validar_unico(p_fk_periodo, 'NOMBRE', p_nombre, p_pk_excluir);
    PERFORM academico_test.fn_area_validar_unico(p_fk_periodo, 'CODIGO', p_abreviacion, p_pk_excluir);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_area_validar(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT)
    IS 'Compone las fn_area_validar_* de crear/actualizar. p_pk_excluir = el area que se edita.';

CREATE OR REPLACE FUNCTION academico_test.fn_area_validar_eliminable(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM academico_test.fn_area_validar_sin_asignaturas(p_pk);
    PERFORM academico_test.fn_area_validar_sin_calificaciones(p_pk);
    PERFORM academico_test.fn_area_validar_sin_criterio_promocion(p_pk);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_area_validar_eliminable(BIGINT)
    IS 'Dependientes que bloquean la baja de un area (23503): asignaturas, calificaciones, criterio de promocion.';

-- --------------------------------------------------------------- asignatura

CREATE OR REPLACE FUNCTION academico_test.fn_subject_validar_existe_activa(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_pk AND ACTIVE = TRUE) THEN
        SELECT NOMBRE INTO v_nombre FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_pk;
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'La asignatura % existe pero esta inactiva', v_nombre USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe una asignatura activa con el PK indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_subject_validar_campos(
    p_fk_area BIGINT, p_nombre VARCHAR, p_abreviacion VARCHAR
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_fk_area IS NULL OR NULLIF(TRIM(p_nombre),'') IS NULL OR NULLIF(TRIM(p_abreviacion),'') IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios de la asignatura' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_subject_validar_nombre_no_vacio(p_nombre VARCHAR)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre),'') IS NULL THEN
        RAISE EXCEPTION 'El nombre de la asignatura no puede ser vacio' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_subject_validar_abreviacion_no_vacia(p_abreviacion VARCHAR)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_abreviacion IS NOT NULL AND NULLIF(TRIM(p_abreviacion),'') IS NULL THEN
        RAISE EXCEPTION 'La abreviacion de la asignatura no puede ser vacia' USING ERRCODE = '22023';
    END IF;
END;
$$;

-- El area padre cuenta como activa solo si su periodo academico y su sede resuelven.
CREATE OR REPLACE FUNCTION academico_test.fn_subject_validar_area_activa(p_fk_area BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TAREA a
          JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = a.FK_TPERIODO_ACADEMICO
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
         WHERE a.PK_TAREA = p_fk_area AND a.ACTIVE = TRUE AND s.FK_TESTABLECIMIENTO IS NOT NULL
    ) THEN
        SELECT NOMBRE INTO v_nombre FROM academico_test.TAREA WHERE PK_TAREA = p_fk_area;
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El area % existe pero esta inactiva', v_nombre USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El area seleccionada no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_subject_validar_asignatura_general(p_fk_area_asignatura BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    IF p_fk_area_asignatura IS NULL THEN RETURN; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TAREA_ASIGNATURA
         WHERE PK_TAREA_ASIGNATURA = p_fk_area_asignatura AND ACTIVE = TRUE
    ) THEN
        SELECT NOMBRE INTO v_nombre FROM academico_test.TAREA_ASIGNATURA
         WHERE PK_TAREA_ASIGNATURA = p_fk_area_asignatura;
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'La asignatura general % ya existe pero esta inactiva', v_nombre USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'La asignatura general seleccionada no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
END;
$$;

-- Crear/actualizar exigen el '#'; el guardado masivo lo acepta opcional y lo quita al guardar.
CREATE OR REPLACE FUNCTION academico_test.fn_subject_validar_color(
    p_color VARCHAR, p_almohadilla_opcional BOOLEAN DEFAULT FALSE
)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_color IS NULL THEN RETURN; END IF;
    IF p_almohadilla_opcional THEN
        IF p_color !~ '^#?([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$' THEN
            RAISE EXCEPTION 'El color (%) debe ser un HEX valido, p.ej. FFAA00', p_color USING ERRCODE = '22023';
        END IF;
    ELSIF p_color !~ '^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$' THEN
        RAISE EXCEPTION 'El color (%) debe ser un HEX valido, p.ej. #FFAA00', p_color USING ERRCODE = '22023';
    END IF;
END;
$$;

-- p_campo: NOMBRE | CODIGO. Unico entre las asignaturas activas del area.
CREATE OR REPLACE FUNCTION academico_test.fn_subject_validar_unico(
    p_fk_area BIGINT, p_campo TEXT, p_valor VARCHAR, p_pk_excluir BIGINT DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_valor IS NULL THEN RETURN; END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA s
         WHERE s.FK_TAREA = p_fk_area AND s.ACTIVE = TRUE
           AND s.PK_TASIGNATURA <> COALESCE(p_pk_excluir, -1)
           AND UPPER(TRIM(CASE p_campo WHEN 'NOMBRE' THEN s.NOMBRE ELSE s.CODIGO END)) = UPPER(TRIM(p_valor))
    ) THEN
        RAISE EXCEPTION 'Ya existe una asignatura con % % en esta area',
            CASE p_campo WHEN 'NOMBRE' THEN 'el nombre' ELSE 'la abreviacion' END, p_valor
            USING ERRCODE = '23505';
    END IF;
END;
$$;

-- El orden es contrato: nombre unico, abreviacion unica.
CREATE OR REPLACE FUNCTION academico_test.fn_subject_validar(
    p_fk_area BIGINT, p_nombre VARCHAR, p_abreviacion VARCHAR, p_pk_excluir BIGINT DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM academico_test.fn_subject_validar_unico(p_fk_area, 'NOMBRE', p_nombre, p_pk_excluir);
    PERFORM academico_test.fn_subject_validar_unico(p_fk_area, 'CODIGO', p_abreviacion, p_pk_excluir);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_subject_validar(BIGINT, VARCHAR, VARCHAR, BIGINT)
    IS 'Compone la unicidad de nombre y abreviacion de crear/actualizar asignatura. p_pk_excluir = la asignatura que se edita.';

CREATE OR REPLACE FUNCTION academico_test.fn_subject_validar_sin_docentes(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
                WHERE da.FK_TASIGNATURA = p_pk AND da.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se puede eliminar la asignatura %: existen asignaciones docente asociadas',
            COALESCE((SELECT NOMBRE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_pk), p_pk::text)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_subject_validar_sin_horarios(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.THORARIO h WHERE h.FK_TASIGNATURA = p_pk AND h.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se puede eliminar la asignatura %: existen horarios asociados',
            COALESCE((SELECT NOMBRE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_pk), p_pk::text)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_subject_validar_sin_plan(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TASIGNATURA_PLAN ap
                WHERE ap.FK_TASIGNATURA = p_pk AND ap.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se puede eliminar la asignatura %: esta asociada a un plan de estudio',
            COALESCE((SELECT NOMBRE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_pk), p_pk::text)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_subject_validar_sin_calificaciones(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TASIGNATURA_NOTA an
                WHERE an.FK_TASIGNATURA = p_pk AND an.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se puede eliminar la asignatura %: existen calificaciones registradas',
            COALESCE((SELECT NOMBRE FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_pk), p_pk::text)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_subject_validar_eliminable(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM academico_test.fn_subject_validar_sin_docentes(p_pk);
    PERFORM academico_test.fn_subject_validar_sin_horarios(p_pk);
    PERFORM academico_test.fn_subject_validar_sin_plan(p_pk);
    PERFORM academico_test.fn_subject_validar_sin_calificaciones(p_pk);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_subject_validar_eliminable(BIGINT)
    IS 'Dependientes que bloquean la baja de una asignatura (23503): docentes, horarios, plan de estudio, calificaciones.';

-- ------------------------------------------------------------------ enfasis

CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_validar_existe_activo(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TENFASIS WHERE PK_TENFASIS = p_pk AND ACTIVE = TRUE) THEN
        SELECT NOMBRE INTO v_nombre FROM academico_test.TENFASIS WHERE PK_TENFASIS = p_pk;
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El enfasis % existe pero esta inactivo', v_nombre USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe un enfasis activo con el PK indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_validar_nombre_no_vacio(p_nombre VARCHAR)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'El nombre del enfasis no puede ser vacio' USING ERRCODE = '22023';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_validar_unico(
    p_fk_sede BIGINT, p_nombre VARCHAR, p_pk_excluir BIGINT DEFAULT NULL
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_nombre IS NULL THEN RETURN; END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TENFASIS
         WHERE FK_TSEDE = p_fk_sede AND ACTIVE = TRUE
           AND PK_TENFASIS <> COALESCE(p_pk_excluir, -1)
           AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(p_nombre))
    ) THEN
        RAISE EXCEPTION 'Ya existe un enfasis con el nombre % en esta sede', p_nombre
            USING ERRCODE = '23505';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_validar_sin_asignaturas(p_pk BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TASIGNATURA s WHERE s.FK_TENFASIS = p_pk AND s.ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se puede eliminar el enfasis %: existen asignaturas asociadas',
            (SELECT NOMBRE FROM academico_test.TENFASIS WHERE PK_TENFASIS = p_pk)
            USING ERRCODE = '23503';
    END IF;
END;
$$;

-- Periodo de la asignatura que pide el enfasis: activo y con sede (el enfasis es de esa sede).
CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_validar_periodo_activo(p_fk_periodo BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TPERIODO_ACADEMICO pa
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
         WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo AND pa.ACTIVE = TRUE
           AND s.FK_TESTABLECIMIENTO IS NOT NULL
    ) THEN
        SELECT NOMBRE INTO v_nombre FROM academico_test.TPERIODO_ACADEMICO
         WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo;
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El periodo academico % ya existe pero esta inactivo', v_nombre USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'El periodo academico seleccionado no existe' USING ERRCODE = 'P0002';
        END IF;
    END IF;
END;
$$;

-- p_id es ambiguo: vale si es un enfasis activo de la sede o una
-- especialidad activa del catalogo global.
CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_validar_seleccion(p_id BIGINT, p_fk_sede BIGINT)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
DECLARE v_nombre VARCHAR(130);
BEGIN
    IF EXISTS (SELECT 1 FROM academico_test.TENFASIS
                WHERE PK_TENFASIS = p_id AND ACTIVE = TRUE AND FK_TSEDE = p_fk_sede)
       OR EXISTS (SELECT 1 FROM academico_test.TESPECIALIDAD WHERE PK_ESPECIALIDAD = p_id AND ACTIVE = TRUE) THEN
        RETURN;
    END IF;
    SELECT NOMBRE INTO v_nombre FROM academico_test.TENFASIS WHERE PK_TENFASIS = p_id;
    IF v_nombre IS NULL THEN
        SELECT NOMBRE INTO v_nombre FROM academico_test.TESPECIALIDAD WHERE PK_ESPECIALIDAD = p_id;
    END IF;
    IF v_nombre IS NOT NULL THEN
        RAISE EXCEPTION 'La especialidad/enfasis % existe pero esta inactiva o pertenece a otra sede', v_nombre
            USING ERRCODE = '22023';
    ELSE
        RAISE EXCEPTION 'La especialidad/enfasis seleccionada no existe' USING ERRCODE = '22023';
    END IF;
END;
$$;
