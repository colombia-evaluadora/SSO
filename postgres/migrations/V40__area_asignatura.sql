-- =============================================================================
-- Área/Asignatura — funciones consolidadas (última versión vigente de cada
-- función del módulo Área (TAREA) / Asignatura (TASIGNATURA) / Énfasis
-- (TENFASIS)), resultado de fusionar las redefiniciones que se acumularon
-- en migraciones sucesivas.
--
-- Migraciones fuente consultadas (orden de aplicación):
--   V40__area_subject_module.sql
--   V103__area_asignatura_mensajes_error_con_nombre.sql
--   V135__query_rows_reportes_modulo_academico.sql (superada por V188, no incluida)
--   V188__fn_area_subject_reporte_listar.sql
--   V193__fn_subject_guardar_bulk_matchea_solo_por_id.sql
--   V194__fn_subject_periodo_listar_expone_enfasis_nombre.sql
--
-- Los helpers de gate (fn_periodo_establecimiento, fn_periodo_sede,
-- fn_periodo_jornada, fn_periodo_gate_escritura, fn_periodo_puede_ver) se
-- movieron a V36_1__gate_permisos_periodo_academico.sql: V37 (Periodo
-- Académico) los necesita y corre antes que este archivo.
-- =============================================================================

SET search_path TO academico_test, public;


-- =============================================================================
-- ÁREA (TAREA)
-- =============================================================================

-- Fuente: V103__area_asignatura_mensajes_error_con_nombre.sql (reemplaza V40)
CREATE OR REPLACE FUNCTION academico_test.fn_area_crear(p_fk_periodo bigint, p_fk_area_asignatura bigint, p_nombre_interno character varying, p_abreviacion character varying, p_orden_reportes numeric DEFAULT 0, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre_aa VARCHAR(130);
    v_establecimiento_id BIGINT;
BEGIN
    v_establecimiento_id := academico_test.fn_periodo_establecimiento(p_fk_periodo);
    -- CU-86e2w4xdt: pasa (sede, jornada) del periodo para que un rol de
    -- nivel sede+jornada (coordinador/docente) con el menu concedido pueda
    -- actuar DENTRO de su (sede, jornada). Sin ellos era fallo seguro (deny).
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_establecimiento_id,
        academico_test.fn_periodo_sede(p_fk_periodo),
        academico_test.fn_periodo_jornada(p_fk_periodo), 'CREAR');
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
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creación del área %s', p_nombre_interno), v_establecimiento_id);
    INSERT INTO academico_test.TAREA
        (CODIGO, NOMBRE, FK_TPERIODO_ACADEMICO, FK_TAREA_ASIGNATURA, ORDEN_REPORTE, CREATED_BY)
    VALUES (p_abreviacion, p_nombre_interno, p_fk_periodo,
            p_fk_area_asignatura, COALESCE(p_orden_reportes, 0), v_audit)
    RETURNING PK_TAREA INTO v_id;
    RETURN v_id;
END;
$function$;

-- Fuente: V103__area_asignatura_mensajes_error_con_nombre.sql (reemplaza V40)
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
    v_establecimiento_id BIGINT;
    v_periodo_id BIGINT;
BEGIN
    -- CU-86e2w4xdt: gate por (EE, sede, jornada) del periodo del area.
    SELECT a.FK_TPERIODO_ACADEMICO,
           academico_test.fn_periodo_establecimiento(a.FK_TPERIODO_ACADEMICO)
      INTO v_periodo_id, v_establecimiento_id
      FROM academico_test.TAREA a WHERE a.PK_TAREA = p_pk;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_establecimiento_id,
        academico_test.fn_periodo_sede(v_periodo_id),
        academico_test.fn_periodo_jornada(v_periodo_id), 'EDITAR');
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
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización del área %s', v_nombre), v_establecimiento_id);
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

-- Fuente: V103__area_asignatura_mensajes_error_con_nombre.sql (reemplaza V40).
-- Dentro de V103 la función aparece definida DOS VECES (línea ~192 y línea
-- ~1194, esta última agregada por el bloque de "consolidación" del propio
-- archivo, que incorpora el bloqueo por TAREA_NOTA y por criterio de
-- promoción tomado de V122). Se toma la ÚLTIMA (más abajo en el archivo) por
-- ser la que queda vigente tras correr V103 completo.
CREATE OR REPLACE FUNCTION academico_test.fn_area_soft_delete(p_pk bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre VARCHAR(130);
    v_establecimiento_id BIGINT;
    v_periodo_id BIGINT;
BEGIN
    -- CU-86e2w4xdt: gate por (EE, sede, jornada) del periodo del area.
    SELECT a.FK_TPERIODO_ACADEMICO,
           academico_test.fn_periodo_establecimiento(a.FK_TPERIODO_ACADEMICO)
      INTO v_periodo_id, v_establecimiento_id
      FROM academico_test.TAREA a WHERE a.PK_TAREA = p_pk;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_establecimiento_id,
        academico_test.fn_periodo_sede(v_periodo_id),
        academico_test.fn_periodo_jornada(v_periodo_id), 'ELIMINAR');
    SELECT NOMBRE INTO v_nombre FROM academico_test.TAREA WHERE PK_TAREA = p_pk;
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA WHERE FK_TAREA = p_pk AND ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el area %: tiene asignaturas asociadas', COALESCE(v_nombre, p_pk::text)
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TAREA_NOTA tn WHERE tn.FK_TAREA = p_pk AND tn.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el area %: existen calificaciones registradas', COALESCE(v_nombre, p_pk::text)
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TCRITERIO_PROMOCION_ASIGNATURA_OBLIGATORIA cpo
         WHERE cpo.FK_TAREA = p_pk AND cpo.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el area %: esta marcada como obligatoria en un criterio de promocion', COALESCE(v_nombre, p_pk::text)
            USING ERRCODE = '23503';
    END IF;
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación del área %s', COALESCE(v_nombre, p_pk::text)), v_establecimiento_id);
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
$$;

-- Fuente: V40__area_subject_module.sql (sin override posterior)
DROP FUNCTION IF EXISTS academico_test.fn_area_listar(BIGINT, TEXT, INT, INT);
DROP FUNCTION IF EXISTS academico_test.fn_area_listar(BIGINT, TEXT, INT, INT, BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_area_listar(BIGINT, TEXT, INT, INT, BIGINT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION academico_test.fn_area_listar(
    p_fk_periodo BIGINT, p_nombre_interno TEXT DEFAULT NULL,
    p_page_index INT DEFAULT 0, p_page_size INT DEFAULT 10,
    p_pk_usuario BIGINT DEFAULT NULL,  -- alcance (global / establecimiento)
    -- Orden: id de columna del front + direccion ('asc'/'desc'), igual que fn_periodo_listar (V37).
    p_sort_by TEXT DEFAULT NULL,
    p_sort_dir TEXT DEFAULT NULL
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

    RETURN QUERY EXECUTE format($q$
        SELECT a.PK_TAREA, a.CODIGO, a.NOMBRE, a.FK_TAREA_ASIGNATURA, a.ORDEN_REPORTE,
               count(*) OVER()::BIGINT
          FROM academico_test.TAREA a
         WHERE a.FK_TPERIODO_ACADEMICO = $1 AND a.ACTIVE = TRUE
           AND academico_test.fn_periodo_puede_ver($5, $1)
           AND ($2 IS NULL OR a.NOMBRE ILIKE '%%' || $2 || '%%')
         ORDER BY %s %s, a.NOMBRE, a.PK_TAREA
         LIMIT NULLIF($4, 0)
        OFFSET COALESCE($3, 0) * COALESCE(NULLIF($4, 0), 0)
    $q$, v_col, v_dir)
    USING p_fk_periodo, NULLIF(TRIM(p_nombre_interno),''), p_page_index, p_page_size, p_pk_usuario;
END;
$$;

-- Fuente: V40__area_subject_module.sql (sin override posterior).
-- Reenvía el error de fn_area_soft_delete via GET STACKED DIAGNOSTICS: no
-- tiene RAISE propio con ID, por eso V103 no lo tocó.
DROP FUNCTION IF EXISTS academico_test.fn_area_bulk_delete(BIGINT[], BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_area_bulk_delete(
    p_ids BIGINT[], p_pk_usuario_solicitante BIGINT
)
RETURNS TABLE (id BIGINT, eliminado BOOLEAN, error_code TEXT, error_mensaje TEXT)
LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_state TEXT; v_msg TEXT;
BEGIN
    -- Gate grueso; el fino por establecimiento lo aplica fn_area_soft_delete.
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, NULL);
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


-- =============================================================================
-- ÉNFASIS (TENFASIS)
-- =============================================================================

-- Fuente: V103__area_asignatura_mensajes_error_con_nombre.sql (reemplaza V40).
-- Este bloque en particular no es un fix de mensajes de error: es la versión
-- tomada de V64 (fix_enfasis_resolver_otro_constant), que corrige
-- c_especialidad_otro de 7 a 2. No tiene RAISE con ID, por eso no aplica la
-- regla de mensajes con nombre.
CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_resolver(
    p_fk_establecimiento BIGINT,
    p_nombre VARCHAR,
    p_codigo VARCHAR DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $function$
DECLARE
    v_id BIGINT;
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    -- Especialidad "Otro" para enfasis creados al vuelo. Ver comentario de
    -- migracion V64: 2 es el valor consistente con los datos existentes,
    -- no el PK real de la fila "Otro" (4) ni el valor previo (7,
    -- "Agropecuario").
    c_especialidad_otro CONSTANT BIGINT := 2;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, p_fk_establecimiento);
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
$function$;

-- Fuente: V103__area_asignatura_mensajes_error_con_nombre.sql (reemplaza V40)
DROP FUNCTION IF EXISTS academico_test.fn_enfasis_desde_seleccion(BIGINT, BIGINT, VARCHAR);
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

-- Fuente: V103__area_asignatura_mensajes_error_con_nombre.sql (reemplaza V40).
-- Overload 1 de 2 (firma: p_pk, p_nombre, p_codigo, p_fk_especialidad,
-- p_pk_usuario_solicitante — 5 parámetros, permite editar CODIGO y
-- FK_TESPECIALIDAD). Confirmado con pg_get_functiondef que ambos oids
-- (39287/39335) son overloads vigentes simultáneos con firmas distintas.
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
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización del énfasis %s', v_nombre), r.FK_TESTABLECIMIENTO);
    UPDATE academico_test.TENFASIS SET
        NOMBRE = v_nombre,
        CODIGO = v_codigo,
        FK_TESPECIALIDAD = COALESCE(p_fk_especialidad, FK_TESPECIALIDAD),
        MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TENFASIS = p_pk;
    RETURN p_pk;
END;
$function$;

-- Fuente: V103__area_asignatura_mensajes_error_con_nombre.sql (reemplaza V40).
-- Overload 2 de 2 (firma: p_pk, p_nombre, p_pk_usuario_solicitante — 3
-- parámetros, solo permite editar NOMBRE; no tiene p_fk_especialidad).
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

    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización del énfasis %s', p_nombre), r.FK_TESTABLECIMIENTO);

    UPDATE academico_test.TENFASIS
    SET
        NOMBRE = p_nombre,
        MODIFIED_BY = v_audit,
        MODIFIED_AT = CURRENT_TIMESTAMP
    WHERE PK_TENFASIS = p_pk;

    RETURN p_pk;
END;
$function$;

-- Fuente: V103__area_asignatura_mensajes_error_con_nombre.sql (reemplaza V40)
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
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación del énfasis %s', v_nombre), v_est);
    UPDATE academico_test.TENFASIS SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TENFASIS = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'El enfasis % existe pero esta inactivo', v_nombre USING ERRCODE = 'P0002';
    END IF;
    RETURN p_pk;
END;
$function$;


-- =============================================================================
-- ASIGNATURA (TASIGNATURA)
-- =============================================================================

-- Fuente: V103__area_asignatura_mensajes_error_con_nombre.sql (reemplaza V40)
CREATE OR REPLACE FUNCTION academico_test.fn_subject_crear(p_fk_area bigint, p_fk_area_asignatura bigint, p_nombre_interno character varying, p_abreviacion character varying, p_fk_enfasis bigint DEFAULT 2, p_color character varying DEFAULT NULL::character varying, p_orden_reportes numeric DEFAULT 0, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id BIGINT; v_est BIGINT; v_periodo BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre_area VARCHAR(130);
    v_nombre_aa VARCHAR(130);
BEGIN
    -- CU-86e2w4xdt: gate por (EE, sede, jornada) del periodo del area.
    SELECT a.FK_TPERIODO_ACADEMICO INTO v_periodo
      FROM academico_test.TAREA a WHERE a.PK_TAREA = p_fk_area;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante,
        academico_test.fn_periodo_establecimiento(v_periodo),
        academico_test.fn_periodo_sede(v_periodo),
        academico_test.fn_periodo_jornada(v_periodo), 'CREAR');
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
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creación de la asignatura %s', p_nombre_interno), v_est);
    INSERT INTO academico_test.TASIGNATURA
        (CODIGO, NOMBRE, FK_TAREA, FK_TAREA_ASIGNATURA, FK_TENFASIS, COLOR, ORDEN_REPORTE, CREATED_BY)
    VALUES (p_abreviacion, p_nombre_interno, p_fk_area, p_fk_area_asignatura, p_fk_enfasis,
            p_color, COALESCE(p_orden_reportes, 0), v_audit)
    RETURNING PK_TASIGNATURA INTO v_id;
    RETURN v_id;
END;
$function$;

-- Fuente: V103__area_asignatura_mensajes_error_con_nombre.sql (reemplaza V40)
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
    v_establecimiento_id BIGINT;
    v_periodo_id BIGINT;
BEGIN
    -- CU-86e2w4xdt: gate por (EE, sede, jornada) del periodo de la asignatura.
    SELECT a.FK_TPERIODO_ACADEMICO,
           academico_test.fn_periodo_establecimiento(a.FK_TPERIODO_ACADEMICO)
      INTO v_periodo_id, v_establecimiento_id
      FROM academico_test.TASIGNATURA s JOIN academico_test.TAREA a ON a.PK_TAREA = s.FK_TAREA
     WHERE s.PK_TASIGNATURA = p_pk;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_establecimiento_id,
        academico_test.fn_periodo_sede(v_periodo_id),
        academico_test.fn_periodo_jornada(v_periodo_id), 'EDITAR');
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
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización de la asignatura %s', v_nombre), v_establecimiento_id);
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

-- Fuente: V103__area_asignatura_mensajes_error_con_nombre.sql (reemplaza V40).
-- Dentro de V103 la función aparece definida DOS VECES (línea ~393 y línea
-- ~1132, esta última agregada por el bloque de "consolidación" del propio
-- archivo, tomada de V116, que suma el bloqueo por plan de estudio). Se toma
-- la ÚLTIMA (más abajo en el archivo).
CREATE OR REPLACE FUNCTION academico_test.fn_subject_soft_delete(p_pk bigint, p_pk_usuario_solicitante bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $$
DECLARE
    v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_nombre VARCHAR(130);
    v_establecimiento_id BIGINT;
    v_periodo_id BIGINT;
BEGIN
    -- CU-86e2w4xdt: gate por (EE, sede, jornada) del periodo de la asignatura.
    SELECT a.FK_TPERIODO_ACADEMICO,
           academico_test.fn_periodo_establecimiento(a.FK_TPERIODO_ACADEMICO)
      INTO v_periodo_id, v_establecimiento_id
      FROM academico_test.TASIGNATURA s JOIN academico_test.TAREA a ON a.PK_TAREA = s.FK_TAREA
     WHERE s.PK_TASIGNATURA = p_pk;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_establecimiento_id,
        academico_test.fn_periodo_sede(v_periodo_id),
        academico_test.fn_periodo_jornada(v_periodo_id), 'ELIMINAR');
    SELECT NOMBRE INTO v_nombre FROM academico_test.TASIGNATURA WHERE PK_TASIGNATURA = p_pk;
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
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA_PLAN ap
         WHERE ap.FK_TASIGNATURA = p_pk AND ap.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar la asignatura %: esta asociada a un plan de estudio', COALESCE(v_nombre, p_pk::text)
            USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA_NOTA an
         WHERE an.FK_TASIGNATURA = p_pk AND an.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar la asignatura %: existen calificaciones registradas', COALESCE(v_nombre, p_pk::text)
            USING ERRCODE = '23503';
    END IF;
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación de la asignatura %s', COALESCE(v_nombre, p_pk::text)), v_establecimiento_id);
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
$$;

-- Fuente: V103__area_asignatura_mensajes_error_con_nombre.sql (reemplaza V40).
-- NOTA / DISCREPANCIA vs. el mapeo original: fn_subject_listar(bigint,
-- bigint) aparece TRES veces en V103 (línea ~603 heredada de V40 vía
-- CREATE OR REPLACE directo, línea ~909 y línea ~1115), pero las tres tienen
-- LA MISMA firma de parámetros (p_fk_area bigint, p_pk_usuario_solicitante
-- bigint DEFAULT NULL) — NO son overloads reales (un overload requiere tipos
-- de parámetro distintos). Cada aparición solo cambia el RETURNS TABLE
-- (agrega/quita la columna enfasis_nombre), por eso el archivo antepone un
-- DROP FUNCTION antes de cada redefinición. Se incluye únicamente la ÚLTIMA
-- (línea ~1115, tomada de V112 fn_subject_listar_devuelve_enfasis_nombre),
-- que es la única que queda vigente al correr V103 completo.
DROP FUNCTION IF EXISTS academico_test.fn_subject_listar(bigint, bigint);
CREATE OR REPLACE FUNCTION academico_test.fn_subject_listar(p_fk_area bigint, p_pk_usuario_solicitante bigint DEFAULT NULL::bigint)
 RETURNS TABLE(id bigint, abreviacion character varying, nombre_interno character varying, asignatura_general_id bigint, enfasis_id bigint, enfasis_nombre character varying, color character varying, orden_reportes numeric)
 LANGUAGE sql
 STABLE
AS $$
    SELECT s.PK_TASIGNATURA, s.CODIGO, s.NOMBRE, s.FK_TAREA_ASIGNATURA, s.FK_TENFASIS,
           e.NOMBRE, s.COLOR, s.ORDEN_REPORTE
      FROM academico_test.TASIGNATURA s
      JOIN academico_test.TAREA a ON a.PK_TAREA = s.FK_TAREA
      LEFT JOIN academico_test.TENFASIS e ON e.PK_TENFASIS = s.FK_TENFASIS AND e.ACTIVE = TRUE
     WHERE s.FK_TAREA = p_fk_area AND s.ACTIVE = TRUE
       -- CU-86e2w4xdt: capability + scope de lectura sobre el periodo del area.
       AND academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante, a.FK_TPERIODO_ACADEMICO)
     ORDER BY s.ORDEN_REPORTE, s.NOMBRE;
$$;

-- Fuente: V193__fn_subject_guardar_bulk_matchea_solo_por_id.sql (reemplaza
-- tanto V40 como las dos redefiniciones internas de V103).
-- OJO: dentro de V103 esta función llegó a incluir (via su bloque de
-- "consolidación" tomado de V118/V122) un loop de bloqueo por dependencias
-- (docente/horario/plan/calificaciones) sobre las asignaturas "huerfanas" y
-- una llamada a fn_audit_declarar. La versión de V193 aquí abajo -- que es la
-- que efectivamente corre después, al ser la migración con mayor número de
-- versión -- NO incluye ese loop de bloqueo ni fn_audit_declarar; solo agrega
-- el fix de matching exclusivo por `id` (vs. fallback por nombre) descrito en
-- su propio comentario. Se deja constancia por si el bloqueo por
-- dependencias en el reemplazo masivo se consideraba vigente.
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
    -- Autorizacion (CU-86e2w4xdt): capability fail-fast.
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, NULL, NULL, NULL, 'EDITAR');
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
    -- Gate fino (CU-86e2w4xdt): capability + scope (EE, sede, jornada) del periodo del area.
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(v_periodo),
        academico_test.fn_periodo_jornada(v_periodo), 'EDITAR');

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
        IF v_color IS NOT NULL AND v_color !~ '^#?([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$' THEN
            RAISE EXCEPTION 'El color (%) debe ser un HEX valido, p.ej. FFAA00', v_color USING ERRCODE = '22023';
        END IF;
        IF v_color IS NOT NULL THEN
            v_color := LTRIM(v_color, '#');
        END IF;
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

        -- Match: solo por PK explicito (id) cuando el item lo trae y
        -- pertenece a una asignatura activa del area -- edicion de una fila
        -- existente. Si no trae id (o no matchea), es alta nueva: SIEMPRE
        -- INSERT. Ya no se cae a buscar por nombre -- el nombre no es unico
        -- y dos altas nuevas del mismo payload pueden compartir nombre
        -- legitimamente (misma asignatura para especialidades distintas).
        v_id := NULLIF(TRIM(it->>'id'),'')::bigint;
        IF v_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM academico_test.TASIGNATURA
             WHERE PK_TASIGNATURA = v_id AND FK_TAREA = p_fk_area AND ACTIVE = TRUE
        ) THEN
            v_id := NULL;
        END IF;
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
                NOMBRE = v_nombre,
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

-- Fuente: V194__fn_subject_periodo_listar_expone_enfasis_nombre.sql (reemplaza V40)
DROP FUNCTION IF EXISTS academico_test.fn_subject_periodo_listar(BIGINT, TEXT, INT, INT, BIGINT, TEXT, TEXT);
CREATE OR REPLACE FUNCTION academico_test.fn_subject_periodo_listar(
    p_fk_periodo BIGINT,
    p_filtro     TEXT DEFAULT NULL,
    p_page_index INT  DEFAULT 0,
    p_page_size  INT  DEFAULT 10,
    p_pk_usuario BIGINT DEFAULT NULL,  -- alcance (global / establecimiento)
    -- Orden: id de columna del front + direccion ('asc'/'desc'), igual que fn_periodo_listar (V37).
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
           AND academico_test.fn_periodo_puede_ver($5, $1)
           AND ($2 IS NULL OR s.NOMBRE ILIKE '%%' || $2 || '%%' OR s.CODIGO ILIKE '%%' || $2 || '%%')
         ORDER BY %s %s, s.NOMBRE, s.PK_TASIGNATURA
         LIMIT NULLIF($4, 0)
        OFFSET COALESCE($3, 0) * COALESCE(NULLIF($4, 0), 0)
    $q$, v_col, v_dir)
    USING p_fk_periodo, NULLIF(TRIM(p_filtro),''), p_page_index, p_page_size, p_pk_usuario;
END;
$$;


-- =============================================================================
-- CATÁLOGOS PARA SELECTS
-- =============================================================================

-- Fuente: V103__area_asignatura_mensajes_error_con_nombre.sql (reemplaza V40).
-- Tomada de V76 (fix_especialidad_enfasis_listar_oculta_espejos): excluye los
-- TENFASIS "espejo" (mismo nombre que la TESPECIALIDAD a la que apuntan,
-- creados por fn_enfasis_desde_seleccion) del listado del selector.
DROP FUNCTION IF EXISTS academico_test.fn_especialidad_enfasis_listar(BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_especialidad_enfasis_listar(
    p_fk_establecimiento BIGINT, p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, nombre VARCHAR, codigo VARCHAR, origen TEXT)
LANGUAGE sql STABLE AS $$
    SELECT e.PK_ESPECIALIDAD, e.NOMBRE, e.CODIGO, 'ESPECIALIDAD'
      FROM academico_test.TESPECIALIDAD e
     WHERE e.ACTIVE = TRUE
    UNION ALL
    SELECT en.PK_TENFASIS, en.NOMBRE, en.CODIGO, 'ENFASIS'
      FROM academico_test.TENFASIS en
     WHERE en.ACTIVE = TRUE AND en.FK_TESTABLECIMIENTO = p_fk_establecimiento
       AND NOT EXISTS (
           SELECT 1 FROM academico_test.TESPECIALIDAD esp
            WHERE esp.PK_ESPECIALIDAD = en.FK_TESPECIALIDAD
              AND UPPER(TRIM(esp.NOMBRE)) = UPPER(TRIM(en.NOMBRE))
       )
       -- CU-86e2w4xdt: los enfasis SI son propios de un establecimiento (a
       -- diferencia de las especialidades, catalogo global de arriba);
       -- capability + scope de LECTURA sobre ese EE (fn_usuario_ee_lectura,
       -- mas amplio que el de escritura: un nivel 3 SI ve -solo lectura- el
       -- EE de sus sedes).
       AND (
           p_pk_usuario_solicitante IS NULL
           OR academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) = 0
           OR (
               academico_test.fn_usuario_puede_en_menu(p_pk_usuario_solicitante, 'PERIODOS_ACADEMICOS', 'VER')
               AND p_fk_establecimiento IN (
                   SELECT establecimiento_id
                     FROM academico_test.fn_usuario_ee_lectura(p_pk_usuario_solicitante)
               )
           )
       )
     ORDER BY 4, 2;
$$;

-- Fuente: V40__area_subject_module.sql (sin override posterior)
DROP FUNCTION IF EXISTS academico_test.fn_area_asignatura_listar();
CREATE OR REPLACE FUNCTION academico_test.fn_area_asignatura_listar(
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, nombre VARCHAR, especialidad_id BIGINT)
LANGUAGE sql STABLE AS $$
    SELECT PK_TAREA_ASIGNATURA, NOMBRE, FK_TESPECIALIDAD
      FROM academico_test.TAREA_ASIGNATURA
     WHERE ACTIVE = TRUE
     ORDER BY NOMBRE;
$$;

-- Fuente: V40__area_subject_module.sql (sin override posterior)
DROP FUNCTION IF EXISTS academico_test.fn_periodo_asignaturas_listar(BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_periodo_areas_asignaturas_listar(BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_areas_asignaturas_listar(
    p_fk_periodo BIGINT, p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
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
       -- CU-86e2w4xdt: capability + scope de lectura sobre el periodo.
       AND academico_test.fn_periodo_puede_ver(p_pk_usuario_solicitante, p_fk_periodo)
     ORDER BY a.ORDEN_REPORTE, a.NOMBRE;
$$;


-- =============================================================================
-- REPORTE
-- =============================================================================

-- Fuente: V188__fn_area_subject_reporte_listar.sql (reemplaza
-- V135__query_rows_reportes_modulo_academico.sql)
CREATE OR REPLACE FUNCTION academico_test.fn_area_subject_reporte_listar(
    p_fk_periodo         BIGINT,
    p_fk_area            BIGINT[] DEFAULT NULL,
    p_fk_asignatura      BIGINT[] DEFAULT NULL,
    p_fk_especialidad    BIGINT[] DEFAULT NULL,
    p_incluir_inactivos  BOOLEAN  DEFAULT FALSE,
    p_pk_usuario         BIGINT   DEFAULT NULL,
    p_page_index         INT      DEFAULT 0,
    p_page_size          INT      DEFAULT 10
)
RETURNS TABLE (
    area_id BIGINT, area_general_name VARCHAR, area_nombre_interno VARCHAR, area_abreviacion VARCHAR,
    asignatura_id BIGINT, asignatura VARCHAR, asignatura_abreviacion VARCHAR,
    especialidad_id BIGINT, especialidad_name VARCHAR,
    orden_reportes NUMERIC, color VARCHAR, total_count BIGINT
)
LANGUAGE sql STABLE AS $$
    SELECT a.PK_TAREA, ta.NOMBRE, a.NOMBRE, a.CODIGO,
           s.PK_TASIGNATURA, s.NOMBRE, s.CODIGO,
           en.PK_TENFASIS, en.NOMBRE,
           s.ORDEN_REPORTE, s.COLOR,
           count(*) OVER()::BIGINT
      FROM academico_test.TAREA a
      JOIN academico_test.TAREA_ASIGNATURA ta ON ta.PK_TAREA_ASIGNATURA = a.FK_TAREA_ASIGNATURA
 LEFT JOIN academico_test.TASIGNATURA s        ON s.FK_TAREA = a.PK_TAREA
                                               AND (p_incluir_inactivos OR s.ACTIVE = TRUE)
 LEFT JOIN academico_test.TENFASIS en          ON en.PK_TENFASIS = s.FK_TENFASIS
     WHERE a.FK_TPERIODO_ACADEMICO = p_fk_periodo
       AND (p_incluir_inactivos OR a.ACTIVE = TRUE)
       AND academico_test.fn_periodo_puede_ver(p_pk_usuario, p_fk_periodo)
       AND (p_fk_area         IS NULL OR CARDINALITY(p_fk_area)         = 0 OR a.PK_TAREA        = ANY(p_fk_area))
       AND (p_fk_asignatura   IS NULL OR CARDINALITY(p_fk_asignatura)   = 0 OR s.PK_TASIGNATURA   = ANY(p_fk_asignatura))
       AND (p_fk_especialidad IS NULL OR CARDINALITY(p_fk_especialidad) = 0 OR en.PK_TENFASIS     = ANY(p_fk_especialidad))
     ORDER BY a.ORDEN_REPORTE, a.NOMBRE, s.ORDEN_REPORTE, s.NOMBRE
     LIMIT NULLIF(p_page_size, 0)
    OFFSET COALESCE(p_page_index, 0) * COALESCE(NULLIF(p_page_size, 0), 0);
$$;
