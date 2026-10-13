-- ===========================================================================
-- V40.3 -- Areas, asignaturas y enfasis: nucleos _interno
-- ===========================================================================
-- QUE HACE: crear/actualizar/eliminar/listar sin permisos de area,
-- asignatura y enfasis, el guardado masivo de asignaturas y la resolucion de
-- enfasis. Validan con V40.2 antes de escribir; gate y auditoria van en V40.4.
-- Reciben p_audit (quien escribe) en vez del usuario solicitante.
-- POR QUE AQUI: capa 2 del modulo (V40.2 / V40.3 / V40.4).
-- DEPENDE DE: V22, V29 (fn_periodo_establecimiento), V40.2.
-- ===========================================================================

SET search_path TO academico_test, public;

-- --------------------------------------------------------------------- area

CREATE OR REPLACE FUNCTION academico_test.fn_area_crear_interno(
    p_fk_periodo         BIGINT,
    p_fk_area_asignatura BIGINT,
    p_nombre_interno     VARCHAR,
    p_abreviacion        VARCHAR,
    p_orden_reportes     NUMERIC,
    p_audit              VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT;
BEGIN
    PERFORM academico_test.fn_area_validar_campos(p_fk_periodo, p_fk_area_asignatura, p_nombre_interno, p_abreviacion);
    PERFORM academico_test.fn_area_validar(p_fk_periodo, p_fk_area_asignatura, p_nombre_interno, p_abreviacion, NULL);

    INSERT INTO academico_test.TAREA
        (CODIGO, NOMBRE, FK_TPERIODO_ACADEMICO, FK_TAREA_ASIGNATURA, ORDEN_REPORTE, CREATED_BY)
    VALUES (p_abreviacion, p_nombre_interno, p_fk_periodo,
            p_fk_area_asignatura, COALESCE(p_orden_reportes, 0), p_audit)
    RETURNING PK_TAREA INTO v_id;
    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_area_crear_interno(BIGINT, BIGINT, VARCHAR, VARCHAR, NUMERIC, VARCHAR)
    IS 'INTERNO: valida e inserta un area en un periodo academico. Lo usa fn_area_crear.';

-- Los NULL conservan el valor actual.
CREATE OR REPLACE FUNCTION academico_test.fn_area_actualizar_interno(
    p_pk                 BIGINT,
    p_fk_area_asignatura BIGINT,
    p_nombre_interno     VARCHAR,
    p_abreviacion        VARCHAR,
    p_orden_reportes     NUMERIC,
    p_audit              VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    r       academico_test.TAREA;
    v_nombre VARCHAR(130);
    v_abrev  VARCHAR(30);
BEGIN
    SELECT * INTO r FROM academico_test.TAREA WHERE PK_TAREA = p_pk;
    PERFORM academico_test.fn_area_validar_nombre_no_vacio(p_nombre_interno);
    PERFORM academico_test.fn_area_validar_codigo_no_vacio(p_abreviacion);
    v_nombre := COALESCE(p_nombre_interno, r.NOMBRE);
    v_abrev  := COALESCE(p_abreviacion, r.CODIGO);
    PERFORM academico_test.fn_area_validar(r.FK_TPERIODO_ACADEMICO, p_fk_area_asignatura, v_nombre, v_abrev, p_pk);

    UPDATE academico_test.TAREA SET
        FK_TAREA_ASIGNATURA = COALESCE(p_fk_area_asignatura, FK_TAREA_ASIGNATURA),
        NOMBRE = v_nombre,
        CODIGO = v_abrev,
        ORDEN_REPORTE = COALESCE(p_orden_reportes, ORDEN_REPORTE),
        MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TAREA = p_pk;
    RETURN p_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_area_actualizar_interno(BIGINT, BIGINT, VARCHAR, VARCHAR, NUMERIC, VARCHAR)
    IS 'INTERNO: valida y actualiza un area existente y activa. Lo usa fn_area_actualizar.';

CREATE OR REPLACE FUNCTION academico_test.fn_area_eliminar_interno(p_pk BIGINT, p_audit VARCHAR)
RETURNS BIGINT LANGUAGE plpgsql AS $$
BEGIN
    PERFORM academico_test.fn_area_validar_eliminable(p_pk);

    UPDATE academico_test.TAREA SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TAREA = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        PERFORM academico_test.fn_area_validar_existe_activa(p_pk);
    END IF;
    RETURN p_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_area_eliminar_interno(BIGINT, VARCHAR)
    IS 'INTERNO: baja logica de un area; 23503 si tiene asignaturas, calificaciones o criterio de promocion, P0002 si ya estaba inactiva. Lo usa fn_area_soft_delete.';

CREATE OR REPLACE FUNCTION academico_test.fn_area_listar_interno(
    p_fk_periodo     BIGINT,
    p_nombre_interno TEXT DEFAULT NULL,
    p_page_index     INT  DEFAULT 0,
    p_page_size      INT  DEFAULT 10,
    p_sort_by        TEXT DEFAULT NULL,
    p_sort_dir       TEXT DEFAULT NULL,
    p_incluir_inactivos BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (id BIGINT, codigo VARCHAR, nombre_interno VARCHAR,
               area_general_id BIGINT, orden_reportes NUMERIC, total_count BIGINT)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'codigo'        THEN 'a.CODIGO'
        WHEN 'nombreinterno' THEN 'a.NOMBRE'
        WHEN 'ordenreportes' THEN 'a.ORDEN_REPORTE'
        ELSE 'a.ORDEN_REPORTE'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'desc' THEN 'DESC' ELSE 'ASC' END;

    -- p_page_size 0/NULL = sin limite.
    RETURN QUERY EXECUTE format($q$
        SELECT a.PK_TAREA, a.CODIGO, a.NOMBRE, a.FK_TAREA_ASIGNATURA, a.ORDEN_REPORTE,
               count(*) OVER()::BIGINT
          FROM academico_test.TAREA a
         WHERE a.FK_TPERIODO_ACADEMICO = $1 AND (a.ACTIVE = TRUE OR $5)
           AND ($2 IS NULL OR a.NOMBRE ILIKE '%%' || $2 || '%%')
         ORDER BY %s %s, a.NOMBRE, a.PK_TAREA
         LIMIT NULLIF($4, 0)
        OFFSET COALESCE($3, 0) * COALESCE(NULLIF($4, 0), 0)
    $q$, v_col, v_dir)
    USING p_fk_periodo, NULLIF(TRIM(p_nombre_interno),''), p_page_index, p_page_size,
          COALESCE(p_incluir_inactivos, FALSE);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_area_listar_interno(BIGINT, TEXT, INT, INT, TEXT, TEXT, BOOLEAN)
    IS 'INTERNO: areas de un periodo academico (activas, o todas con p_incluir_inactivos), paginadas y ordenadas, sin alcance. Lo usan fn_area_listar y fn_area_subject_reporte_listar.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_areas_asignaturas_listar_interno(p_fk_periodo BIGINT)
RETURNS TABLE (area_id BIGINT, area_nombre VARCHAR, asignaturas JSONB)
LANGUAGE sql STABLE AS $$
    SELECT a.PK_TAREA, a.NOMBRE,
           COALESCE(
               (SELECT jsonb_agg(
                          jsonb_build_object('id', s.PK_TASIGNATURA,
                                             'abreviacion', s.CODIGO,
                                             'nombreInterno', s.NOMBRE)
                          ORDER BY s.ORDEN_REPORTE, s.NOMBRE)
                  FROM academico_test.TASIGNATURA s
                 WHERE s.FK_TAREA = a.PK_TAREA AND s.ACTIVE = TRUE),
               '[]'::jsonb)
      FROM academico_test.TAREA a
     WHERE a.FK_TPERIODO_ACADEMICO = p_fk_periodo AND a.ACTIVE = TRUE
     ORDER BY a.ORDEN_REPORTE, a.NOMBRE;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_areas_asignaturas_listar_interno(BIGINT)
    IS 'INTERNO: areas activas de un periodo con sus asignaturas activas en JSONB, sin alcance. Lo usa fn_periodo_areas_asignaturas_listar.';

-- ------------------------------------------------------------------ enfasis

-- Especialidad "Otro" para enfasis creados al vuelo. 2 es el valor
-- consistente con los datos existentes, no el PK real de la fila "Otro" (4).
CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_resolver_interno(
    p_fk_sede            BIGINT,
    p_nombre             VARCHAR,
    p_codigo             VARCHAR,
    p_audit              VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_id   BIGINT;
    v_next INT;
    c_especialidad_otro CONSTANT BIGINT := 2;
BEGIN
    SELECT PK_TENFASIS INTO v_id FROM academico_test.TENFASIS
     WHERE FK_TSEDE = p_fk_sede AND ACTIVE = TRUE
       AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(p_nombre));
    IF v_id IS NULL THEN
        -- CODIGO autonumerico por sede; el lock serializa el MAX()+1.
        IF p_codigo IS NULL THEN
            PERFORM pg_advisory_xact_lock(hashtext('tenfasis:sede:' || p_fk_sede::text));
            SELECT COALESCE(MAX(CODIGO::int), -1) + 1 INTO v_next
              FROM academico_test.TENFASIS
             WHERE FK_TSEDE = p_fk_sede AND CODIGO ~ '^[0-9]+$';
        END IF;
        INSERT INTO academico_test.TENFASIS (CODIGO, NOMBRE, FK_TESPECIALIDAD, FK_TESTABLECIMIENTO, FK_TSEDE, CREATED_BY)
        SELECT COALESCE(p_codigo, lpad(v_next::text, 5, '0')), p_nombre, c_especialidad_otro,
               s.FK_TESTABLECIMIENTO, s.PK_TSEDE, p_audit
          FROM academico_test.TSEDE s WHERE s.PK_TSEDE = p_fk_sede
        RETURNING PK_TENFASIS INTO v_id;
    END IF;
    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_enfasis_resolver_interno(BIGINT, VARCHAR, VARCHAR, VARCHAR)
    IS 'INTERNO: devuelve el enfasis activo de la sede con ese nombre o lo crea con especialidad "Otro". No declara etiqueta de auditoria: corre dentro de bucles. Lo usan fn_enfasis_resolver y fn_subject_guardar_bulk_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_desde_seleccion(p_fk_periodo bigint, p_id bigint, p_audit character varying)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_sede   BIGINT;
    v_enf    BIGINT;
    v_nombre VARCHAR(130);
    v_next   INT;
BEGIN
    IF p_id IS NULL THEN RETURN NULL; END IF;
    PERFORM academico_test.fn_enfasis_validar_periodo_activo(p_fk_periodo);
    v_sede := academico_test.fn_periodo_sede(p_fk_periodo);
    PERFORM academico_test.fn_enfasis_validar_seleccion(p_id, v_sede);

    SELECT PK_TENFASIS INTO v_enf FROM academico_test.TENFASIS
     WHERE PK_TENFASIS = p_id AND ACTIVE = TRUE AND FK_TSEDE = v_sede;
    IF v_enf IS NOT NULL THEN RETURN v_enf; END IF;

    SELECT NOMBRE INTO v_nombre FROM academico_test.TESPECIALIDAD
     WHERE PK_ESPECIALIDAD = p_id AND ACTIVE = TRUE;
    PERFORM pg_advisory_xact_lock(hashtext('tenfasis:sede:' || v_sede::text));
    -- Si la especialidad ya se eligio antes en la sede, se reusa su enfasis.
    SELECT PK_TENFASIS INTO v_enf FROM academico_test.TENFASIS
     WHERE FK_TESPECIALIDAD = p_id AND FK_TSEDE = v_sede AND ACTIVE = TRUE
       AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(v_nombre))
     LIMIT 1;
    IF v_enf IS NOT NULL THEN RETURN v_enf; END IF;
    SELECT COALESCE(MAX(CODIGO::int), -1) + 1 INTO v_next
      FROM academico_test.TENFASIS
     WHERE FK_TSEDE = v_sede AND CODIGO ~ '^[0-9]+$';
    INSERT INTO academico_test.TENFASIS (CODIGO, NOMBRE, FK_TESPECIALIDAD, FK_TESTABLECIMIENTO, FK_TSEDE, CREATED_BY)
    SELECT lpad(v_next::text, 5, '0'), v_nombre, p_id, s.FK_TESTABLECIMIENTO, s.PK_TSEDE, p_audit
      FROM academico_test.TSEDE s WHERE s.PK_TSEDE = v_sede
    RETURNING PK_TENFASIS INTO v_enf;
    RETURN v_enf;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_enfasis_desde_seleccion(BIGINT, BIGINT, VARCHAR)
    IS 'INTERNO: p_id es un enfasis de la sede del periodo (se devuelve tal cual) o una especialidad global (crea/reusa su enfasis en la sede). Sin permisos ni etiqueta de auditoria. La usan fn_subject_crear_interno, fn_subject_actualizar_interno y fn_subject_guardar_bulk_interno.';

-- Un NULL en p_nombre deja NOMBRE en NULL (contrato heredado del endpoint).
CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_actualizar_interno(
    p_pk BIGINT, p_nombre VARCHAR, p_audit VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_sede BIGINT;
BEGIN
    SELECT FK_TSEDE INTO v_sede FROM academico_test.TENFASIS WHERE PK_TENFASIS = p_pk;
    PERFORM academico_test.fn_enfasis_validar_nombre_no_vacio(p_nombre);
    PERFORM academico_test.fn_enfasis_validar_unico(v_sede, p_nombre, p_pk);

    UPDATE academico_test.TENFASIS
       SET NOMBRE = p_nombre, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TENFASIS = p_pk;
    RETURN p_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_enfasis_actualizar_interno(BIGINT, VARCHAR, VARCHAR)
    IS 'INTERNO: valida y renombra un enfasis existente y activo. Lo usa fn_enfasis_actualizar.';

CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_eliminar_interno(p_pk BIGINT, p_audit VARCHAR)
RETURNS BIGINT LANGUAGE plpgsql AS $$
BEGIN
    PERFORM academico_test.fn_enfasis_validar_sin_asignaturas(p_pk);

    UPDATE academico_test.TENFASIS SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TENFASIS = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        PERFORM academico_test.fn_enfasis_validar_existe_activo(p_pk);
    END IF;
    RETURN p_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_enfasis_eliminar_interno(BIGINT, VARCHAR)
    IS 'INTERNO: baja logica de un enfasis; 23503 si tiene asignaturas activas, P0002 si ya estaba inactivo. Lo usa fn_enfasis_soft_delete.';

-- Los enfasis son propios de la sede; las especialidades, catalogo global.
CREATE OR REPLACE FUNCTION academico_test.fn_especialidad_enfasis_listar_interno(
    p_fk_sede BIGINT, p_incluir_enfasis BOOLEAN DEFAULT TRUE
)
RETURNS TABLE (id BIGINT, nombre VARCHAR, codigo VARCHAR, origen TEXT)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    -- plpgsql: FK_TSEDE la agrega V40, que en un deploy puede re-aplicarse despues.
    RETURN QUERY
    SELECT e.PK_ESPECIALIDAD, e.NOMBRE, e.CODIGO, 'ESPECIALIDAD'::TEXT
      FROM academico_test.TESPECIALIDAD e
     WHERE e.ACTIVE = TRUE
    UNION ALL
    SELECT en.PK_TENFASIS, en.NOMBRE, en.CODIGO, 'ENFASIS'::TEXT
      FROM academico_test.TENFASIS en
     WHERE p_incluir_enfasis IS TRUE
       AND en.ACTIVE = TRUE AND en.FK_TSEDE = p_fk_sede
       AND NOT EXISTS (
           SELECT 1 FROM academico_test.TESPECIALIDAD esp
            WHERE esp.PK_ESPECIALIDAD = en.FK_TESPECIALIDAD
              AND UPPER(TRIM(esp.NOMBRE)) = UPPER(TRIM(en.NOMBRE))
       )
     ORDER BY 4, 2;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_especialidad_enfasis_listar_interno(BIGINT, BOOLEAN)
    IS 'INTERNO: especialidades activas del catalogo y, si p_incluir_enfasis, los enfasis propios de la sede que no repiten una especialidad. Lo usa fn_especialidad_enfasis_listar, que resuelve el alcance.';

-- --------------------------------------------------------------- asignatura

CREATE OR REPLACE FUNCTION academico_test.fn_subject_crear_interno(
    p_fk_area            BIGINT,
    p_fk_area_asignatura BIGINT,
    p_nombre_interno     VARCHAR,
    p_abreviacion        VARCHAR,
    p_fk_enfasis         BIGINT,
    p_color              VARCHAR,
    p_orden_reportes     NUMERIC,
    p_audit              VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_periodo BIGINT; v_enfasis BIGINT;
BEGIN
    PERFORM academico_test.fn_subject_validar_campos(p_fk_area, p_nombre_interno, p_abreviacion);
    PERFORM academico_test.fn_subject_validar_area_activa(p_fk_area);
    PERFORM academico_test.fn_subject_validar_asignatura_general(p_fk_area_asignatura);
    PERFORM academico_test.fn_subject_validar_color(p_color);
    SELECT FK_TPERIODO_ACADEMICO INTO v_periodo FROM academico_test.TAREA WHERE PK_TAREA = p_fk_area;
    v_enfasis := academico_test.fn_enfasis_desde_seleccion(v_periodo, p_fk_enfasis, p_audit);
    PERFORM academico_test.fn_subject_validar(p_fk_area, p_nombre_interno, p_abreviacion, NULL);

    INSERT INTO academico_test.TASIGNATURA
        (CODIGO, NOMBRE, FK_TAREA, FK_TAREA_ASIGNATURA, FK_TENFASIS, COLOR, ORDEN_REPORTE, CREATED_BY)
    VALUES (p_abreviacion, p_nombre_interno, p_fk_area, p_fk_area_asignatura, v_enfasis,
            p_color, COALESCE(p_orden_reportes, 0), p_audit)
    RETURNING PK_TASIGNATURA INTO v_id;
    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_subject_crear_interno(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR, NUMERIC, VARCHAR)
    IS 'INTERNO: valida e inserta una asignatura en un area activa; resuelve el enfasis con fn_enfasis_desde_seleccion. Lo usa fn_subject_crear.';

-- Los NULL conservan el valor actual.
CREATE OR REPLACE FUNCTION academico_test.fn_subject_actualizar_interno(
    p_pk                 BIGINT,
    p_fk_area_asignatura BIGINT,
    p_nombre_interno     VARCHAR,
    p_abreviacion        VARCHAR,
    p_fk_enfasis         BIGINT,
    p_color              VARCHAR,
    p_orden_reportes     NUMERIC,
    p_audit              VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    r         academico_test.TASIGNATURA;
    v_nombre  VARCHAR(130);
    v_codigo  VARCHAR(30);
    v_enfasis BIGINT;
    v_periodo BIGINT;
BEGIN
    SELECT * INTO r FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_pk;
    PERFORM academico_test.fn_subject_validar_nombre_no_vacio(p_nombre_interno);
    PERFORM academico_test.fn_subject_validar_abreviacion_no_vacia(p_abreviacion);
    PERFORM academico_test.fn_subject_validar_asignatura_general(p_fk_area_asignatura);
    PERFORM academico_test.fn_subject_validar_color(p_color);
    v_nombre := COALESCE(p_nombre_interno, r.NOMBRE);
    v_codigo := COALESCE(p_abreviacion, r.CODIGO);
    IF p_fk_enfasis IS NOT NULL THEN
        SELECT FK_TPERIODO_ACADEMICO INTO v_periodo FROM academico_test.TAREA WHERE PK_TAREA = r.FK_TAREA;
        v_enfasis := academico_test.fn_enfasis_desde_seleccion(v_periodo, p_fk_enfasis, p_audit);
    ELSE
        v_enfasis := r.FK_TENFASIS;
    END IF;
    PERFORM academico_test.fn_subject_validar(r.FK_TAREA, v_nombre, v_codigo, p_pk);

    UPDATE academico_test.TASIGNATURA SET
        FK_TAREA_ASIGNATURA = COALESCE(p_fk_area_asignatura, FK_TAREA_ASIGNATURA),
        NOMBRE = v_nombre,
        CODIGO = v_codigo,
        FK_TENFASIS = v_enfasis,
        COLOR = COALESCE(p_color, COLOR),
        ORDEN_REPORTE = COALESCE(p_orden_reportes, ORDEN_REPORTE),
        MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TASIGNATURA = p_pk;
    RETURN p_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_subject_actualizar_interno(BIGINT, BIGINT, VARCHAR, VARCHAR, BIGINT, VARCHAR, NUMERIC, VARCHAR)
    IS 'INTERNO: valida y actualiza una asignatura existente y activa. Lo usa fn_subject_actualizar.';

CREATE OR REPLACE FUNCTION academico_test.fn_subject_eliminar_interno(p_pk BIGINT, p_audit VARCHAR)
RETURNS BIGINT LANGUAGE plpgsql AS $$
BEGIN
    PERFORM academico_test.fn_subject_validar_eliminable(p_pk);

    UPDATE academico_test.TASIGNATURA SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TASIGNATURA = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        PERFORM academico_test.fn_subject_validar_existe_activa(p_pk);
    END IF;
    RETURN p_pk;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_subject_eliminar_interno(BIGINT, VARCHAR)
    IS 'INTERNO: baja logica de una asignatura; 23503 si tiene docentes, horarios, plan o calificaciones, P0002 si ya estaba inactiva. Lo usa fn_subject_soft_delete.';

-- Reemplaza el set de asignaturas del area. El set se identifica por `id`,
-- no por NOMBRE: el nombre no es unico dentro del area.
CREATE OR REPLACE FUNCTION academico_test.fn_subject_guardar_bulk_interno(
    p_fk_area BIGINT, p_asignaturas JSONB, p_audit VARCHAR
)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_sede BIGINT; v_periodo BIGINT; v_count INT := 0; it jsonb;
    v_id BIGINT; v_nombre VARCHAR(130); v_codigo VARCHAR(30);
    v_aa BIGINT; v_enf BIGINT; v_esp BIGINT; v_color VARCHAR(10); v_orden NUMERIC;
    v_enf_name TEXT;
BEGIN
    PERFORM academico_test.fn_subject_validar_area_activa(p_fk_area);
    SELECT FK_TPERIODO_ACADEMICO INTO v_periodo FROM academico_test.TAREA WHERE PK_TAREA = p_fk_area;
    v_sede := academico_test.fn_periodo_sede(v_periodo);

    UPDATE academico_test.TASIGNATURA t
       SET ACTIVE = FALSE, MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE t.FK_TAREA = p_fk_area AND t.ACTIVE = TRUE
       AND NOT EXISTS (
           SELECT 1 FROM jsonb_array_elements(COALESCE(p_asignaturas, '[]'::jsonb)) e
            WHERE NULLIF(TRIM(e->>'id'), '')::bigint = t.PK_TASIGNATURA
       );

    FOR it IN SELECT * FROM jsonb_array_elements(COALESCE(p_asignaturas, '[]'::jsonb))
    LOOP
        v_nombre   := it->>'nombreInterno';
        v_codigo   := it->>'abreviacion';
        v_color    := NULLIF(it->>'color','');
        v_orden    := COALESCE(NULLIF(it->>'ordenReportes','')::NUMERIC, 0);
        v_enf_name := NULLIF(TRIM(it->>'especialidad'),'');

        PERFORM academico_test.fn_subject_validar_campos(p_fk_area, v_nombre, v_codigo);
        PERFORM academico_test.fn_subject_validar_color(v_color, TRUE);
        IF v_color IS NOT NULL THEN
            v_color := LTRIM(v_color, '#');
        END IF;
        v_aa := NULLIF(TRIM(it->>'asignaturaGeneral'),'')::bigint;
        PERFORM academico_test.fn_subject_validar_asignatura_general(v_aa);

        -- Un nombre de ESPECIALIDAD del catalogo conserva su FK_TESPECIALIDAD;
        -- cualquier otro se resuelve por nombre (especialidad "Otro").
        v_enf := NULL;
        IF v_enf_name IS NOT NULL THEN
            SELECT PK_ESPECIALIDAD INTO v_esp FROM academico_test.TESPECIALIDAD
             WHERE ACTIVE = TRUE AND UPPER(TRIM(NOMBRE)) = UPPER(v_enf_name) LIMIT 1;
            IF v_esp IS NOT NULL THEN
                v_enf := academico_test.fn_enfasis_desde_seleccion(v_periodo, v_esp, p_audit);
            ELSE
                v_enf := academico_test.fn_enfasis_resolver_interno(v_sede, v_enf_name, NULL, p_audit);
            END IF;
        END IF;

        -- Sin id (o con uno que no es de esta area) es alta nueva; no se busca
        -- por nombre porque dos altas del mismo payload pueden compartirlo.
        v_id := NULLIF(TRIM(it->>'id'),'')::bigint;
        IF v_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM academico_test.TASIGNATURA
             WHERE PK_TASIGNATURA = v_id AND FK_TAREA = p_fk_area AND ACTIVE = TRUE
        ) THEN
            v_id := NULL;
        END IF;
        PERFORM academico_test.fn_subject_validar_unico(p_fk_area, 'CODIGO', v_codigo, v_id);

        IF v_id IS NULL THEN
            INSERT INTO academico_test.TASIGNATURA
                (CODIGO, NOMBRE, FK_TAREA, FK_TAREA_ASIGNATURA, FK_TENFASIS, COLOR, ORDEN_REPORTE, CREATED_BY)
            VALUES (v_codigo, v_nombre, p_fk_area, v_aa, v_enf, v_color, v_orden, p_audit);
        ELSE
            UPDATE academico_test.TASIGNATURA SET
                CODIGO = v_codigo, NOMBRE = v_nombre, FK_TAREA_ASIGNATURA = v_aa,
                FK_TENFASIS = v_enf, COLOR = v_color, ORDEN_REPORTE = v_orden,
                MODIFIED_BY = p_audit, MODIFIED_AT = CURRENT_TIMESTAMP
             WHERE PK_TASIGNATURA = v_id;
        END IF;
        v_count := v_count + 1;
    END LOOP;
    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_subject_guardar_bulk_interno(BIGINT, JSONB, VARCHAR)
    IS 'INTERNO: reemplaza las asignaturas de un area por el payload (baja de las que no vienen por id, alta/edicion del resto). Devuelve cuantas guardo. Lo usa fn_subject_guardar_bulk.';

CREATE OR REPLACE FUNCTION academico_test.fn_subject_listar_interno(
    p_fk_area BIGINT, p_incluir_inactivos BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(id bigint, abreviacion character varying, nombre_interno character varying,
              asignatura_general_id bigint, enfasis_id bigint, enfasis_nombre character varying,
              color character varying, orden_reportes numeric)
LANGUAGE sql STABLE AS $$
    SELECT s.PK_TASIGNATURA, s.CODIGO, s.NOMBRE, s.FK_TAREA_ASIGNATURA, s.FK_TENFASIS,
           e.NOMBRE, s.COLOR, s.ORDEN_REPORTE
      FROM academico_test.TASIGNATURA s
      JOIN academico_test.TAREA a ON a.PK_TAREA = s.FK_TAREA
      LEFT JOIN academico_test.TENFASIS e ON e.PK_TENFASIS = s.FK_TENFASIS AND e.ACTIVE = TRUE
     WHERE s.FK_TAREA = p_fk_area AND (s.ACTIVE = TRUE OR p_incluir_inactivos IS TRUE)
     ORDER BY s.ORDEN_REPORTE, s.NOMBRE;
$$;

COMMENT ON FUNCTION academico_test.fn_subject_listar_interno(BIGINT, BOOLEAN)
    IS 'INTERNO: asignaturas de un area (activas, o todas con p_incluir_inactivos) con su enfasis, sin alcance. Lo usan fn_subject_listar y fn_area_subject_reporte_listar.';

CREATE OR REPLACE FUNCTION academico_test.fn_subject_periodo_listar_interno(
    p_fk_periodo BIGINT,
    p_filtro     TEXT DEFAULT NULL,
    p_page_index INT  DEFAULT 0,
    p_page_size  INT  DEFAULT 10,
    p_sort_by    TEXT DEFAULT NULL,
    p_sort_dir   TEXT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, codigo VARCHAR, nombre_interno VARCHAR,
               area_id BIGINT, area_nombre VARCHAR,
               asignatura_general_id BIGINT, enfasis_id BIGINT, enfasis_nombre VARCHAR,
               color VARCHAR, orden_reportes NUMERIC, total_count BIGINT)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col TEXT;
    v_dir TEXT;
BEGIN
    v_col := CASE lower(coalesce(p_sort_by, ''))
        WHEN 'codigo'        THEN 's.CODIGO'
        WHEN 'nombreinterno' THEN 's.NOMBRE'
        WHEN 'areanombre'    THEN 'a.NOMBRE'
        WHEN 'ordenreportes' THEN 's.ORDEN_REPORTE'
        ELSE 'a.NOMBRE'
    END;
    v_dir := CASE WHEN lower(coalesce(p_sort_dir, '')) = 'desc' THEN 'DESC' ELSE 'ASC' END;

    RETURN QUERY EXECUTE format($q$
        SELECT s.PK_TASIGNATURA, s.CODIGO, s.NOMBRE, a.PK_TAREA, a.NOMBRE,
               s.FK_TAREA_ASIGNATURA, s.FK_TENFASIS, e.NOMBRE, s.COLOR, s.ORDEN_REPORTE,
               count(*) OVER()::BIGINT
          FROM academico_test.TASIGNATURA s
          JOIN academico_test.TAREA a ON a.PK_TAREA = s.FK_TAREA AND a.ACTIVE = TRUE
          LEFT JOIN academico_test.TENFASIS e ON e.PK_TENFASIS = s.FK_TENFASIS AND e.ACTIVE = TRUE
         WHERE a.FK_TPERIODO_ACADEMICO = $1 AND s.ACTIVE = TRUE
           AND ($2 IS NULL OR s.NOMBRE ILIKE '%%' || $2 || '%%' OR s.CODIGO ILIKE '%%' || $2 || '%%')
         ORDER BY %s %s, s.NOMBRE, s.PK_TASIGNATURA
         LIMIT NULLIF($4, 0)
        OFFSET COALESCE($3, 0) * COALESCE(NULLIF($4, 0), 0)
    $q$, v_col, v_dir)
    USING p_fk_periodo, NULLIF(TRIM(p_filtro),''), p_page_index, p_page_size;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_subject_periodo_listar_interno(BIGINT, TEXT, INT, INT, TEXT, TEXT)
    IS 'INTERNO: asignaturas activas de las areas activas de un periodo, paginadas y ordenadas, sin alcance. Lo usa fn_subject_periodo_listar.';
