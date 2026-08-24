-- Modulo area/asignatura: varios RAISE EXCEPTION exponian PKs crudos de
-- entidades que ya existen (conflicto de negocio o "no existe/inactiva" sobre
-- una FK pasada por el caller). Se agrega resolucion de nombre igual que en
-- V99 (fn_periodo_crear/actualizar): SELECT adicional justo antes del RAISE,
-- sin tocar logica/ERRCODE/firma.
--
-- Tocadas (regla 4/5 del criterio: FK "no existe o esta inactiva" resuelta
-- ignorando ACTIVE, o "no existe activo/a con PK %" del propio PK buscado;
-- si el lookup encuentra el nombre se informa "existe pero esta inactivo/a",
-- si no se deja el mensaje generico sin ID):
--   fn_area_crear            -> FK_TAREA_ASIGNATURA (area general)
--   fn_area_actualizar       -> PK propio (area) + FK_TAREA_ASIGNATURA
--   fn_area_soft_delete      -> PK propio (area), en ambos RAISE (bloqueo por
--                                asignaturas asociadas y "no existe activa");
--                                el primero es el ejemplo explicito de la
--                                regla 3 (PK que el propio caller paso y cuya
--                                existencia ya se confirma implicitamente por
--                                tener asignaturas asociadas) -> se agrega un
--                                SELECT de nombre al inicio de la funcion.
--   fn_subject_crear         -> FK_TAREA (area) + FK_TAREA_ASIGNATURA (asig. general)
--   fn_subject_actualizar    -> PK propio (asignatura) + FK_TAREA_ASIGNATURA
--   fn_subject_soft_delete   -> PK propio (asignatura), en los 4 RAISE (3
--                                bloqueos por dependencias + "no existe activa");
--                                se agrega un SELECT de nombre al inicio.
--   fn_subject_guardar_bulk  -> FK_TAREA (area, una vez) + FK_TAREA_ASIGNATURA
--                                por item del bulk (asignatura general)
--   fn_enfasis_actualizar (39287, firma con p_codigo/p_fk_especialidad)
--                             -> PK propio (enfasis) + FK_TESPECIALIDAD
--   fn_enfasis_actualizar (39335, firma solo con p_nombre)
--                             -> PK propio (enfasis); no tiene p_fk_especialidad
--   fn_enfasis_desde_seleccion -> FK_periodo ("no existe o esta inactivo") y el
--                                p_id ambiguo (puede ser enfasis O especialidad):
--                                se agrega lookup de nombre contra ambas tablas
--                                (ignorando ACTIVE/establecimiento) antes del
--                                mensaje generico.
--   fn_enfasis_soft_delete   -> PK propio (enfasis), en los 2 RAISE de "no
--                                existe activo" + el de bloqueo por
--                                asignaturas asociadas (se reusa el nombre ya
--                                resuelto al validar existencia/gate al inicio).
--
-- Se confirmo via pg_get_functiondef que ambos oids de fn_enfasis_actualizar
-- (39287 y 39335) son overloads vigentes con firmas distintas -- las dos se
-- tocan.
--
-- Sin cambios (regla 1/2/6: ya son strings legibles ingresados por el
-- usuario, o validaciones sin ID):
--   fn_area_crear/actualizar    -> "Ya existe un area con el nombre/codigo %"
--                                   (v_nombre/v_abrev, strings), "Faltan campos..."
--   fn_subject_crear/actualizar/guardar_bulk -> "Ya existe una asignatura con
--                                   el nombre/abreviacion %" (strings), color
--                                   HEX invalido, "Faltan campos..."
--   fn_area_bulk_delete         -> solo reenvia el error de fn_area_soft_delete
--                                   via GET STACKED DIAGNOSTICS, no tiene RAISE
--                                   propio con ID
--   fn_enfasis_actualizar (ambas) -> "Ya existe un enfasis con el
--                                   nombre/codigo %" (strings)
--   fn_enfasis_resolver         -> no tiene RAISE con ID (solo crea)
--   fn_especialidad_enfasis_listar -> funcion SQL sin RAISE
--
-- fn_enfasis_soft_delete y fn_enfasis_desde_seleccion se incluyen porque
-- exponian PKs crudos de enfasis/especialidad/periodo en mensajes de
-- conflicto o de FK invalida, igual patron que area/asignatura.

CREATE OR REPLACE FUNCTION academico_test.fn_area_crear(p_fk_periodo bigint, p_fk_area_asignatura bigint, p_nombre_interno character varying, p_abreviacion character varying, p_orden_reportes numeric DEFAULT 0, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre_aa VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, academico_test.fn_periodo_establecimiento(p_fk_periodo));
    IF p_fk_periodo IS NULL OR p_fk_area_asignatura IS NULL
       OR NULLIF(TRIM(p_nombre_interno),'') IS NULL OR NULLIF(TRIM(p_abreviacion),'') IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios del area' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM academico_test.TAREA_ASIGNATURA
         WHERE PK_TAREA_ASIGNATURA = p_fk_area_asignatura AND ACTIVE = TRUE
    ) THEN
        SELECT NOMBRE INTO v_nombre_aa FROM academico_test.TAREA_ASIGNATURA
         WHERE PK_TAREA_ASIGNATURA = p_fk_area_asignatura;
        IF v_nombre_aa IS NOT NULL THEN
            RAISE EXCEPTION 'El area general % ya existe pero esta inactiva', v_nombre_aa USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El area general seleccionada no existe' USING ERRCODE = '23503';
        END IF;
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
           AND UPPER(TRIM(a.CODIGO)) = UPPER(TRIM(p_abreviacion))
    ) THEN
        RAISE EXCEPTION 'Ya existe un area con el codigo % en este periodo academico',
            p_abreviacion USING ERRCODE = '23505';
    END IF;
    INSERT INTO academico_test.TAREA
        (CODIGO, NOMBRE, FK_TPERIODO_ACADEMICO, FK_TAREA_ASIGNATURA, ORDEN_REPORTE, CREATED_BY)
    VALUES (p_abreviacion, p_nombre_interno, p_fk_periodo,
            p_fk_area_asignatura, COALESCE(p_orden_reportes, 0), v_audit)
    RETURNING PK_TAREA INTO v_id;
    RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_area_actualizar(p_pk bigint, p_fk_area_asignatura bigint DEFAULT NULL::bigint, p_nombre_interno character varying DEFAULT NULL::character varying, p_abreviacion character varying DEFAULT NULL::character varying, p_orden_reportes numeric DEFAULT NULL::numeric, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    r academico_test.TAREA;
    v_nombre VARCHAR(130); v_abrev VARCHAR(30);
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre_pk VARCHAR(130);
    v_nombre_aa VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(a.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TAREA a WHERE a.PK_TAREA = p_pk));
    SELECT * INTO r FROM academico_test.TAREA WHERE PK_TAREA = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        SELECT NOMBRE INTO v_nombre_pk FROM academico_test.TAREA WHERE PK_TAREA = p_pk;
        IF v_nombre_pk IS NOT NULL THEN
            RAISE EXCEPTION 'El area % existe pero esta inactiva', v_nombre_pk USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe un area activa con el PK indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
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
        SELECT NOMBRE INTO v_nombre_aa FROM academico_test.TAREA_ASIGNATURA
         WHERE PK_TAREA_ASIGNATURA = p_fk_area_asignatura;
        IF v_nombre_aa IS NOT NULL THEN
            RAISE EXCEPTION 'El area general % ya existe pero esta inactiva', v_nombre_aa USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El area general seleccionada no existe' USING ERRCODE = '23503';
        END IF;
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
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_area_soft_delete(p_pk bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(a.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TAREA a WHERE a.PK_TAREA = p_pk));
    SELECT NOMBRE INTO v_nombre FROM academico_test.TAREA WHERE PK_TAREA = p_pk;
    -- No se puede eliminar un area con asignaturas activas.
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA WHERE FK_TAREA = p_pk AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el area %: tiene asignaturas asociadas', COALESCE(v_nombre, p_pk::text)
            USING ERRCODE = '23503';
    END IF;
    UPDATE academico_test.TAREA SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TAREA = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'El area % existe pero esta inactiva', v_nombre USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe un area activa con el PK indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    RETURN p_pk;
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_subject_crear(p_fk_area bigint, p_fk_area_asignatura bigint, p_nombre_interno character varying, p_abreviacion character varying, p_fk_enfasis bigint DEFAULT 2, p_color character varying DEFAULT NULL::character varying, p_orden_reportes numeric DEFAULT 0, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id BIGINT; v_est BIGINT; v_periodo BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre_area VARCHAR(130);
    v_nombre_aa VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(a.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TAREA a WHERE a.PK_TAREA = p_fk_area));
    IF p_fk_area IS NULL OR NULLIF(TRIM(p_nombre_interno),'') IS NULL
       OR NULLIF(TRIM(p_abreviacion),'') IS NULL THEN
        RAISE EXCEPTION 'Faltan campos obligatorios de la asignatura' USING ERRCODE = '22023';
    END IF;
    -- Periodo y establecimiento del area (via periodo -> sede). Valida que el area exista.
    SELECT a.FK_TPERIODO_ACADEMICO, s.FK_TESTABLECIMIENTO INTO v_periodo, v_est
      FROM academico_test.TAREA a
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = a.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE a.PK_TAREA = p_fk_area AND a.ACTIVE = TRUE;
    IF v_est IS NULL THEN
        SELECT NOMBRE INTO v_nombre_area FROM academico_test.TAREA WHERE PK_TAREA = p_fk_area;
        IF v_nombre_area IS NOT NULL THEN
            RAISE EXCEPTION 'El area % existe pero esta inactiva', v_nombre_area USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El area seleccionada no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
    IF p_fk_area_asignatura IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TAREA_ASIGNATURA
         WHERE PK_TAREA_ASIGNATURA = p_fk_area_asignatura AND ACTIVE = TRUE
    ) THEN
        SELECT NOMBRE INTO v_nombre_aa FROM academico_test.TAREA_ASIGNATURA
         WHERE PK_TAREA_ASIGNATURA = p_fk_area_asignatura;
        IF v_nombre_aa IS NOT NULL THEN
            RAISE EXCEPTION 'La asignatura general % ya existe pero esta inactiva', v_nombre_aa USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'La asignatura general seleccionada no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
    IF p_color IS NOT NULL AND p_color !~ '^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$' THEN
        RAISE EXCEPTION 'El color (%) debe ser un HEX valido, p.ej. #FFAA00', p_color USING ERRCODE = '22023';
    END IF;
    -- Especialidad/enfasis (opcional): resolver la seleccion del combo. Si es una
    -- especialidad global, se crea (o reusa) un enfasis del establecimiento con su
    -- info; si ya es un enfasis, se usa tal cual. Deja p_fk_enfasis = PK_TENFASIS.
    p_fk_enfasis := academico_test.fn_enfasis_desde_seleccion(v_periodo, p_fk_enfasis, v_audit);
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
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_subject_actualizar(p_pk bigint, p_fk_area_asignatura bigint DEFAULT NULL::bigint, p_nombre_interno character varying DEFAULT NULL::character varying, p_abreviacion character varying DEFAULT NULL::character varying, p_fk_enfasis bigint DEFAULT NULL::bigint, p_color character varying DEFAULT NULL::character varying, p_orden_reportes numeric DEFAULT NULL::numeric, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    r academico_test.TASIGNATURA;
    v_nombre VARCHAR(130); v_codigo VARCHAR(30); v_enfasis BIGINT; v_est BIGINT; v_periodo BIGINT;
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre_pk VARCHAR(130);
    v_nombre_aa VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(a.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TASIGNATURA s JOIN academico_test.TAREA a ON a.PK_TAREA = s.FK_TAREA
         WHERE s.PK_TASIGNATURA = p_pk));
    SELECT * INTO r FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        SELECT NOMBRE INTO v_nombre_pk FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_pk;
        IF v_nombre_pk IS NOT NULL THEN
            RAISE EXCEPTION 'La asignatura % existe pero esta inactiva', v_nombre_pk USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe una asignatura activa con el PK indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
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
        SELECT NOMBRE INTO v_nombre_aa FROM academico_test.TAREA_ASIGNATURA
         WHERE PK_TAREA_ASIGNATURA = p_fk_area_asignatura;
        IF v_nombre_aa IS NOT NULL THEN
            RAISE EXCEPTION 'La asignatura general % ya existe pero esta inactiva', v_nombre_aa USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'La asignatura general seleccionada no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
    IF p_color IS NOT NULL AND p_color !~ '^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$' THEN
        RAISE EXCEPTION 'El color (%) debe ser un HEX valido, p.ej. #FFAA00', p_color USING ERRCODE = '22023';
    END IF;
    v_nombre  := COALESCE(p_nombre_interno, r.NOMBRE);
    v_codigo  := COALESCE(p_abreviacion, r.CODIGO);
    -- Especialidad/enfasis (si viene): resolver la seleccion del combo contra el
    -- establecimiento del area. Especialidad global -> crea/reusa enfasis; enfasis
    -- -> tal cual. Si no viene, conserva el actual.
    IF p_fk_enfasis IS NOT NULL THEN
        SELECT a.FK_TPERIODO_ACADEMICO, s.FK_TESTABLECIMIENTO INTO v_periodo, v_est
          FROM academico_test.TAREA a
          JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = a.FK_TPERIODO_ACADEMICO
          JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
         WHERE a.PK_TAREA = r.FK_TAREA;
        v_enfasis := academico_test.fn_enfasis_desde_seleccion(v_periodo, p_fk_enfasis, v_audit);
    ELSE
        v_enfasis := r.FK_TENFASIS;
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
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_subject_soft_delete(p_pk bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(a.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TASIGNATURA s JOIN academico_test.TAREA a ON a.PK_TAREA = s.FK_TAREA
         WHERE s.PK_TASIGNATURA = p_pk));
    SELECT NOMBRE INTO v_nombre FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_pk;
    -- Bloqueo por dependencias (solo filas activas).
    IF EXISTS (
        SELECT 1 FROM academico_test.TDOCENTE_ASIGNATURA da
         WHERE da.FK_TASIGNATURA = p_pk AND da.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar la asignatura %: existen asignaciones docente asociadas', COALESCE(v_nombre, p_pk::text)
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.THORARIO h
         WHERE h.FK_TASIGNATURA = p_pk AND h.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar la asignatura %: existen horarios asociados', COALESCE(v_nombre, p_pk::text)
            USING ERRCODE = '23503';
    END IF;
    -- Procesos academicos activos: ya hay calificaciones registradas para la asignatura.
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA_NOTA an
         WHERE an.FK_TASIGNATURA = p_pk AND an.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar la asignatura %: existen calificaciones registradas', COALESCE(v_nombre, p_pk::text)
            USING ERRCODE = '23503';
    END IF;
    UPDATE academico_test.TASIGNATURA SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TASIGNATURA = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        IF v_nombre IS NOT NULL THEN
            RAISE EXCEPTION 'La asignatura % existe pero esta inactiva', v_nombre USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe una asignatura activa con el PK indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    RETURN p_pk;
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_subject_guardar_bulk(p_fk_area bigint, p_asignaturas jsonb, p_pk_usuario_solicitante bigint)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_est BIGINT; v_periodo BIGINT; v_count INT := 0; it jsonb;
    v_id BIGINT; v_nombre VARCHAR(130); v_codigo VARCHAR(30);
    v_aa BIGINT; v_enf BIGINT; v_esp BIGINT; v_color VARCHAR(10); v_orden NUMERIC;
    v_enf_name TEXT;
    v_nombre_area VARCHAR(130);
    v_nombre_aa VARCHAR(130);
BEGIN
    IF NOT academico_test.fn_periodo_usuario_puede_gestionar(p_pk_usuario_solicitante) THEN
        RAISE EXCEPTION 'El usuario no tiene el nivel de permisos necesario para realizar esta accion'
            USING ERRCODE = '42501';
    END IF;
    -- Periodo y establecimiento del area (valida que el area exista/activa).
    SELECT a.FK_TPERIODO_ACADEMICO, s.FK_TESTABLECIMIENTO INTO v_periodo, v_est
      FROM academico_test.TAREA a
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = a.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE a.PK_TAREA = p_fk_area AND a.ACTIVE = TRUE;
    IF v_est IS NULL THEN
        SELECT NOMBRE INTO v_nombre_area FROM academico_test.TAREA WHERE PK_TAREA = p_fk_area;
        IF v_nombre_area IS NOT NULL THEN
            RAISE EXCEPTION 'El area % existe pero esta inactiva', v_nombre_area USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'El area seleccionada no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
    -- Gate fino: el establecimiento del area debe estar en el alcance del usuario.
    IF NOT academico_test.fn_periodo_usuario_puede_escribir(p_pk_usuario_solicitante, v_est) THEN
        RAISE EXCEPTION 'El usuario no puede gestionar datos academicos de este establecimiento'
            USING ERRCODE = '42501';
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
        v_enf_name := NULLIF(TRIM(it->>'especialidad'),'');

        IF NULLIF(TRIM(v_nombre),'') IS NULL OR NULLIF(TRIM(v_codigo),'') IS NULL THEN
            RAISE EXCEPTION 'Faltan campos obligatorios de la asignatura' USING ERRCODE = '22023';
        END IF;
        IF v_color IS NOT NULL AND v_color !~ '^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$' THEN
            RAISE EXCEPTION 'El color (%) debe ser un HEX valido, p.ej. #FFAA00', v_color USING ERRCODE = '22023';
        END IF;
        -- Area general: el front manda el id (fk_area_asignatura), no el nombre.
        v_aa := NULLIF(TRIM(it->>'asignaturaGeneral'),'')::bigint;
        IF v_aa IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM academico_test.TAREA_ASIGNATURA
             WHERE PK_TAREA_ASIGNATURA = v_aa AND ACTIVE = TRUE
        ) THEN
            SELECT NOMBRE INTO v_nombre_aa FROM academico_test.TAREA_ASIGNATURA
             WHERE PK_TAREA_ASIGNATURA = v_aa;
            IF v_nombre_aa IS NOT NULL THEN
                RAISE EXCEPTION 'La asignatura general % ya existe pero esta inactiva', v_nombre_aa USING ERRCODE = '23503';
            ELSE
                RAISE EXCEPTION 'La asignatura general seleccionada no existe' USING ERRCODE = '23503';
            END IF;
        END IF;
        -- Especialidad: si el nombre corresponde a una ESPECIALIDAD global del
        -- catalogo, se resuelve preservandola (crea/reusa enfasis con su
        -- FK_TESPECIALIDAD y codigo incremental, via fn_enfasis_desde_seleccion).
        -- Si es un nombre nuevo (no del catalogo global), cae al resolver por
        -- nombre (enfasis con especialidad "Otro").
        v_enf := NULL;
        IF v_enf_name IS NOT NULL THEN
            SELECT PK_ESPECIALIDAD INTO v_esp FROM academico_test.TESPECIALIDAD
             WHERE ACTIVE = TRUE AND UPPER(TRIM(NOMBRE)) = UPPER(v_enf_name) LIMIT 1;
            IF v_esp IS NOT NULL THEN
                v_enf := academico_test.fn_enfasis_desde_seleccion(v_periodo, v_esp, v_audit);
            ELSE
                v_enf := academico_test.fn_enfasis_resolver(v_est, v_enf_name, NULL, p_pk_usuario_solicitante);
            END IF;
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
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_actualizar(p_pk bigint, p_nombre character varying DEFAULT NULL::character varying, p_codigo character varying DEFAULT NULL::character varying, p_fk_especialidad bigint DEFAULT NULL::bigint, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    r academico_test.TENFASIS;
    v_nombre VARCHAR(130); v_codigo VARCHAR(30);
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre_pk VARCHAR(130);
    v_nombre_esp VARCHAR(130);
BEGIN
    SELECT * INTO r FROM academico_test.TENFASIS WHERE PK_TENFASIS = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        SELECT NOMBRE INTO v_nombre_pk FROM academico_test.TENFASIS WHERE PK_TENFASIS = p_pk;
        IF v_nombre_pk IS NOT NULL THEN
            RAISE EXCEPTION 'El enfasis % existe pero esta inactivo', v_nombre_pk USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe un enfasis activo con el PK indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, r.FK_TESTABLECIMIENTO);
    IF p_nombre IS NOT NULL AND NULLIF(TRIM(p_nombre),'') IS NULL THEN
        RAISE EXCEPTION 'El nombre del enfasis no puede ser vacio' USING ERRCODE = '22023';
    END IF;
    IF p_codigo IS NOT NULL AND NULLIF(TRIM(p_codigo),'') IS NULL THEN
        RAISE EXCEPTION 'El codigo del enfasis no puede ser vacio' USING ERRCODE = '22023';
    END IF;
    IF p_fk_especialidad IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM academico_test.TESPECIALIDAD WHERE PK_ESPECIALIDAD = p_fk_especialidad AND ACTIVE = TRUE
    ) THEN
        SELECT NOMBRE INTO v_nombre_esp FROM academico_test.TESPECIALIDAD WHERE PK_ESPECIALIDAD = p_fk_especialidad;
        IF v_nombre_esp IS NOT NULL THEN
            RAISE EXCEPTION 'La especialidad % ya existe pero esta inactiva', v_nombre_esp USING ERRCODE = '23503';
        ELSE
            RAISE EXCEPTION 'La especialidad seleccionada no existe' USING ERRCODE = '23503';
        END IF;
    END IF;
    v_nombre := COALESCE(p_nombre, r.NOMBRE);
    v_codigo := COALESCE(p_codigo, r.CODIGO);
    IF EXISTS (
        SELECT 1 FROM academico_test.TENFASIS
         WHERE FK_TESTABLECIMIENTO = r.FK_TESTABLECIMIENTO AND ACTIVE = TRUE AND PK_TENFASIS <> p_pk
           AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(v_nombre))
    ) THEN
        RAISE EXCEPTION 'Ya existe un enfasis con el nombre % en este establecimiento', v_nombre
            USING ERRCODE = '23505';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TENFASIS
         WHERE FK_TESTABLECIMIENTO = r.FK_TESTABLECIMIENTO AND ACTIVE = TRUE AND PK_TENFASIS <> p_pk
           AND UPPER(TRIM(CODIGO)) = UPPER(TRIM(v_codigo))
    ) THEN
        RAISE EXCEPTION 'Ya existe un enfasis con el codigo % en este establecimiento', v_codigo
            USING ERRCODE = '23505';
    END IF;
    UPDATE academico_test.TENFASIS SET
        NOMBRE = v_nombre,
        CODIGO = v_codigo,
        FK_TESPECIALIDAD = COALESCE(p_fk_especialidad, FK_TESPECIALIDAD),
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TENFASIS = p_pk;
    RETURN p_pk;
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_actualizar(p_pk bigint, p_nombre character varying DEFAULT NULL::character varying, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    r academico_test.TENFASIS;
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre_pk VARCHAR(130);
BEGIN
    SELECT *
    INTO r
    FROM academico_test.TENFASIS
    WHERE PK_TENFASIS = p_pk
      AND ACTIVE = TRUE;

    IF NOT FOUND THEN
        SELECT NOMBRE INTO v_nombre_pk FROM academico_test.TENFASIS WHERE PK_TENFASIS = p_pk;
        IF v_nombre_pk IS NOT NULL THEN
            RAISE EXCEPTION 'El enfasis % existe pero esta inactivo', v_nombre_pk
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe un enfasis activo con el PK indicado'
                USING ERRCODE = 'P0002';
        END IF;
    END IF;

    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        r.FK_TESTABLECIMIENTO
    );

    IF p_nombre IS NOT NULL
       AND NULLIF(TRIM(p_nombre), '') IS NULL THEN
        RAISE EXCEPTION 'El nombre del enfasis no puede ser vacio'
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM academico_test.TENFASIS
        WHERE FK_TESTABLECIMIENTO = r.FK_TESTABLECIMIENTO
          AND ACTIVE = TRUE
          AND PK_TENFASIS <> p_pk
          AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(p_nombre))
    ) THEN
        RAISE EXCEPTION
            'Ya existe un enfasis con el nombre % en este establecimiento',
            p_nombre
            USING ERRCODE = '23505';
    END IF;

    UPDATE academico_test.TENFASIS
    SET
        NOMBRE = p_nombre,
        MODIFIED_BY = v_audit,
        MODIFIED_AT = CURRENT_TIMESTAMP
    WHERE PK_TENFASIS = p_pk;

    RETURN p_pk;
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_desde_seleccion(p_fk_periodo bigint, p_id bigint, p_audit character varying)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_est    BIGINT;          -- establecimiento del periodo (periodo -> sede -> establecimiento)
    v_enf    BIGINT;
    v_nombre VARCHAR(130);
    v_next   INT;
    v_nombre_periodo VARCHAR(130);
    v_nombre_cualquiera VARCHAR(130);
BEGIN
    IF p_id IS NULL THEN RETURN NULL; END IF;
    -- Resolver establecimiento a partir del periodo (periodo -> sede -> establecimiento).
    SELECT s.FK_TESTABLECIMIENTO INTO v_est
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo AND pa.ACTIVE = TRUE;
    IF v_est IS NULL THEN
        SELECT NOMBRE INTO v_nombre_periodo FROM academico_test.TPERIODO_ACADEMICO
         WHERE PK_TPERIODO_ACADEMICO = p_fk_periodo;
        IF v_nombre_periodo IS NOT NULL THEN
            RAISE EXCEPTION 'El periodo academico % ya existe pero esta inactivo', v_nombre_periodo
                USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'El periodo academico seleccionado no existe' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    -- 1) ¿Ya es un enfasis del establecimiento?
    SELECT PK_TENFASIS INTO v_enf FROM academico_test.TENFASIS
     WHERE PK_TENFASIS = p_id AND ACTIVE = TRUE AND FK_TESTABLECIMIENTO = v_est;
    IF v_enf IS NOT NULL THEN RETURN v_enf; END IF;
    -- 2) ¿Es una especialidad global activa? -> resolver-o-crear enfasis con su nombre.
    SELECT NOMBRE INTO v_nombre FROM academico_test.TESPECIALIDAD
     WHERE PK_ESPECIALIDAD = p_id AND ACTIVE = TRUE;
    IF v_nombre IS NULL THEN
        -- p_id es ambiguo (puede referirse a un enfasis o a una especialidad):
        -- se intenta resolver el nombre ignorando ACTIVE/establecimiento solo
        -- para informar mejor el mensaje, sin cambiar el resultado (sigue
        -- fallando igual).
        SELECT NOMBRE INTO v_nombre_cualquiera FROM academico_test.TENFASIS WHERE PK_TENFASIS = p_id;
        IF v_nombre_cualquiera IS NULL THEN
            SELECT NOMBRE INTO v_nombre_cualquiera FROM academico_test.TESPECIALIDAD WHERE PK_ESPECIALIDAD = p_id;
        END IF;
        IF v_nombre_cualquiera IS NOT NULL THEN
            RAISE EXCEPTION 'La especialidad/enfasis % existe pero esta inactiva o pertenece a otro establecimiento', v_nombre_cualquiera
                USING ERRCODE = '22023';
        ELSE
            RAISE EXCEPTION 'La especialidad/enfasis seleccionada no existe' USING ERRCODE = '22023';
        END IF;
    END IF;
    -- Serializar la creacion por establecimiento (codigo incremental sin choques).
    PERFORM pg_advisory_xact_lock(hashtext('tenfasis:' || v_est::text));
    -- Reusar el enfasis ya creado para esta especialidad en el establecimiento
    -- (misma especialidad + mismo nombre): si vuelve a elegirse, no se crea otro.
    SELECT PK_TENFASIS INTO v_enf FROM academico_test.TENFASIS
     WHERE FK_TESPECIALIDAD = p_id AND FK_TESTABLECIMIENTO = v_est AND ACTIVE = TRUE
       AND UPPER(TRIM(NOMBRE)) = UPPER(TRIM(v_nombre))
     LIMIT 1;
    IF v_enf IS NOT NULL THEN RETURN v_enf; END IF;
    -- Crear: FK_TESPECIALIDAD = la especialidad elegida; NOMBRE = el de la
    -- especialidad; CODIGO incremental (00000, 00001, ...) por establecimiento,
    -- calculado entre los codigos puramente numericos existentes.
    SELECT COALESCE(MAX(CODIGO::int), -1) + 1 INTO v_next
      FROM academico_test.TENFASIS
     WHERE FK_TESTABLECIMIENTO = v_est AND CODIGO ~ '^[0-9]+$';
    INSERT INTO academico_test.TENFASIS (CODIGO, NOMBRE, FK_TESPECIALIDAD, FK_TESTABLECIMIENTO, CREATED_BY)
    VALUES (lpad(v_next::text, 5, '0'), v_nombre, p_id, v_est, p_audit)
    RETURNING PK_TENFASIS INTO v_enf;
    RETURN v_enf;
END;
$function$;

CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_soft_delete(p_pk bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_est BIGINT; v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre VARCHAR(130);
    v_nombre_pk VARCHAR(130);
BEGIN
    SELECT FK_TESTABLECIMIENTO, NOMBRE INTO v_est, v_nombre FROM academico_test.TENFASIS
     WHERE PK_TENFASIS = p_pk AND ACTIVE = TRUE;
    IF v_est IS NULL THEN
        SELECT NOMBRE INTO v_nombre_pk FROM academico_test.TENFASIS WHERE PK_TENFASIS = p_pk;
        IF v_nombre_pk IS NOT NULL THEN
            RAISE EXCEPTION 'El enfasis % existe pero esta inactivo', v_nombre_pk USING ERRCODE = 'P0002';
        ELSE
            RAISE EXCEPTION 'No existe un enfasis activo con el PK indicado' USING ERRCODE = 'P0002';
        END IF;
    END IF;
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_est);
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA s WHERE s.FK_TENFASIS = p_pk AND s.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el enfasis %: existen asignaturas asociadas', v_nombre
            USING ERRCODE = '23503';
    END IF;
    UPDATE academico_test.TENFASIS SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TENFASIS = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'El enfasis % existe pero esta inactivo', v_nombre USING ERRCODE = 'P0002';
    END IF;
    RETURN p_pk;
END;
$function$;
