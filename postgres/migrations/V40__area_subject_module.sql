-- ===========================================================================
-- V40 — Modulo de Area (TAREA) / Asignatura (TASIGNATURA) / Enfasis (TENFASIS).
-- TAREA_ASIGNATURA; la asignatura cuelga del area y opcionalmente de un enfasis
-- (especialidad creada al vuelo, ligada al establecimiento, con
-- FK_TESPECIALIDAD = 7 "Otro"). El campo del front "abreviacion" de la
-- asignatura es su CODIGO.
-- ===========================================================================

SET search_path TO academico_test, public;

-- ---------------------------------------------------------------------------
-- Helpers de alcance por rol reutilizables (usados por V40-V46 y por V100/
-- V101/V102/V193).
--   fn_periodo_establecimiento(periodo) -> establecimiento dueño del periodo.
--   fn_periodo_sede(periodo)            -> TPERIODO_ACADEMICO.FK_TSEDE.
--   fn_periodo_jornada(periodo)         -> TPERIODO_ACADEMICO.FK_TLV_JORNADA.
--   fn_periodo_gate_escritura(usuario, establecimiento [, sede, jornada, accion])
--     -> gate de ESCRITURA de toda la cascada academica.
--
-- CU-86e2w4xdt (2026-08): fn_periodo_gate_escritura deja de autorizar por
--   listas fijas de FK_TROL (fn_periodo_usuario_puede_gestionar / _escribir)
--   y pasa a ser un wrapper de UNA LINEA sobre fn_assert_permiso_seccion
--   (V29), menu 'PERIODOS_ACADEMICOS': capability configurable por el super
--   admin via TROL_MENU/TUSUARIO_ROL_PERMISO + scope por categoria de rol
--   (nivel 1 territorial = todos los EE; nivel 2 = fn_usuario_ee_accesibles;
--   nivel 3 = par (sede, jornada) en fn_usuario_sedes_jornadas_accesibles) +
--   bypass del SUPER_ADMIN. La firma posicional vieja (usuario, EE) se
--   conserva: sede/jornada/accion se anaden AL FINAL con DEFAULT, asi que
--   los ~45 call sites de 2 argumentos de V40/V103/V104..V109 siguen
--   compilando sin tocarlos (FALLO SEGURO: sin sede+jornada, un usuario de
--   nivel 3 no satisface el scope y se le DENIEGA). Ver
--   docs/gate-permisos-por-menu-analysis.md.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_establecimiento(p_fk_periodo BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT s.FK_TESTABLECIMIENTO
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_sede(p_fk_periodo BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT pa.FK_TSEDE
      FROM academico_test.TPERIODO_ACADEMICO pa
     WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_jornada(p_fk_periodo BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT pa.FK_TLV_JORNADA
      FROM academico_test.TPERIODO_ACADEMICO pa
     WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_sede(BIGINT)
    IS 'FK_TSEDE del periodo academico (NULL si no existe). Para pasar el par (sede, jornada) a fn_periodo_gate_escritura, que es lo que el scope de nivel 3 (ADMINISTRATIVOS_SEDES) necesita.';
COMMENT ON FUNCTION academico_test.fn_periodo_jornada(BIGINT)
    IS 'FK_TLV_JORNADA del periodo academico (NULL si no existe). Todo lo que cuelga de un periodo hereda su jornada.';

-- El DROP de la firma vieja (BIGINT, BIGINT) es obligatorio: pasa de 2 a 5
-- parametros; sin el, la variante vieja sobreviviria y toda llamada de 2
-- argumentos quedaria ambigua (42725 "function is not unique").
DROP FUNCTION IF EXISTS academico_test.fn_periodo_gate_escritura(BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_gate_escritura(
    p_pk_usuario          BIGINT,
    p_fk_establecimiento  BIGINT,
    p_fk_tsede            BIGINT  DEFAULT NULL,
    p_fk_tlv_jornada      BIGINT  DEFAULT NULL,
    p_accion              VARCHAR DEFAULT 'EDITAR'
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario, 'PERIODOS_ACADEMICOS', p_accion,
        p_fk_establecimiento, p_fk_tsede, p_fk_tlv_jornada);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_gate_escritura(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR)
    IS 'Gate de ESCRITURA de la cascada academica (areas, asignaturas, enfasis, criterios, escalas, grados, grupos, planes, horarios, asignaciones) y de periodos / periodos de evaluacion / descansos. Wrapper de una linea sobre fn_assert_permiso_seccion (V29), menu ''PERIODOS_ACADEMICOS''. CAPABILITY: TROL_MENU concede / TUSUARIO_ROL_PERMISO recorta. SCOPE: nivel 1 territorial = todos los EE; nivel 2 = fn_usuario_ee_accesibles; nivel 3 = par (sede, jornada) en fn_usuario_sedes_jornadas_accesibles. BYPASS: SUPER_ADMIN. Ya NO usa fn_periodo_usuario_puede_gestionar / _puede_escribir ni listas de FK_TROL. Firma posicional vieja (usuario, EE) conservada; p_fk_tsede/p_fk_tlv_jornada/p_accion al final con DEFAULT. FALLO SEGURO: sin sede+jornada un usuario de nivel 3 no satisface el scope y se le deniega. Con los tres NULL solo se exige capability (bulk_delete).';

-- ---------------------------------------------------------------------------
-- Helpers de alcance de MATRICULA (CU-86e2w4xdt). La matricula cuelga de un
-- grupo (TMATRICULA.FK_TGRUPO -> TGRUPO.FK_TGRADO -> TGRADO.FK_TPERIODO_ACADEMICO),
-- y de ahi hereda sede+jornada+EE igual que las areas/asignaturas del periodo.
-- Se colocan aqui (V40) para que el modulo de matricula (V159-V168, V200),
-- muy posterior, los tenga disponibles. Referencian solo tablas de V22
-- (TMATRICULA/TGRUPO/TGRADO), asi que son LANGUAGE sql sin problema.
--   fn_grupo_periodo(grupo)         -> periodo academico del grupo.
--   fn_grupo_jornada(grupo)         -> TGRUPO.FK_TLV_JORNADA (la del grupo, no
--                                      la del periodo: es la autoritativa para
--                                      esa matricula, ver u_tgrupo_1).
--   fn_grupo_establecimiento(grupo) -> EE dueño (grupo -> grado -> periodo -> sede).
--   fn_matricula_grupo(matricula)   -> TMATRICULA.FK_TGRUPO.
--   fn_matricula_gate_escritura(usuario, grupo [, accion]) -> gate de la
--     seccion Matricula: wrapper de una linea sobre fn_assert_permiso_seccion
--     (V29), menu 'MATRICULA'. Mismo modelo capability + scope que
--     fn_periodo_gate_escritura. Con p_fk_tgrupo NULL solo exige capability.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_grupo_periodo(p_fk_tgrupo BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT g.FK_TPERIODO_ACADEMICO
      FROM academico_test.TGRUPO gr
      JOIN academico_test.TGRADO g ON g.PK_TGRADO = gr.FK_TGRADO
     WHERE gr.PK_TGRUPO = p_fk_tgrupo;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_jornada(p_fk_tgrupo BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT gr.FK_TLV_JORNADA
      FROM academico_test.TGRUPO gr
     WHERE gr.PK_TGRUPO = p_fk_tgrupo;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_grupo_establecimiento(p_fk_tgrupo BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT academico_test.fn_periodo_establecimiento(academico_test.fn_grupo_periodo(p_fk_tgrupo));
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_grupo(p_fk_tmatricula BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
    SELECT m.FK_TGRUPO
      FROM academico_test.TMATRICULA m
     WHERE m.PK_TMATRICULA = p_fk_tmatricula;
$$;

COMMENT ON FUNCTION academico_test.fn_grupo_jornada(BIGINT)
    IS 'FK_TLV_JORNADA del grupo (NULL si no existe). Es la jornada autoritativa de toda matricula de ese grupo (u_tgrupo_1 = fk_tgrado, fk_tlv_jornada, nombre).';

CREATE OR REPLACE FUNCTION academico_test.fn_matricula_gate_escritura(
    p_pk_usuario  BIGINT,
    p_fk_tgrupo   BIGINT,
    p_accion      VARCHAR DEFAULT 'EDITAR'
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario, 'MATRICULA', p_accion,
        academico_test.fn_grupo_establecimiento(p_fk_tgrupo),
        academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(p_fk_tgrupo)),
        academico_test.fn_grupo_jornada(p_fk_tgrupo));
END;
$$;

COMMENT ON FUNCTION academico_test.fn_matricula_gate_escritura(BIGINT, BIGINT, VARCHAR)
    IS 'Gate de ESCRITURA de la seccion Matricula (estudiante/acudiente al ligarlos, matricula, socioeconomico, archivos, matricula directa). Wrapper de una linea sobre fn_assert_permiso_seccion (V29), menu ''MATRICULA''. Mismo modelo que fn_periodo_gate_escritura: CAPABILITY dinamica (TROL_MENU concede / TUSUARIO_ROL_PERMISO recorta) + SCOPE por categoria de rol (nivel 1 territorial = todos los EE; nivel 2 = fn_usuario_ee_accesibles; nivel 3 = par (sede, jornada) del grupo en fn_usuario_sedes_jornadas_accesibles) + BYPASS del SUPER_ADMIN. El scope se resuelve por el grupo: TMATRICULA -> TGRUPO -> TGRADO -> TPERIODO_ACADEMICO. Con p_fk_tgrupo NULL las tres coordenadas quedan NULL y solo se exige capability (altas de persona sin sede todavia).';

-- fn_matricula_puede_ver: version BOOLEAN del gate, para el WHERE del LISTADO
-- de matricula (fn_matricula_listar, V200) -- reemplaza a
-- fn_periodo_usuario_puede_ver. Misma decision de capability + scope que
-- fn_matricula_gate_escritura pero SIN lanzar: devuelve TRUE/FALSE por fila.
-- Reusa los mismos helpers de V29 (fn_usuario_categoria_rol_nivel,
-- fn_usuario_puede_en_menu, fn_usuario_ee_accesibles,
-- fn_usuario_sedes_jornadas_accesibles) que consume fn_assert_permiso_seccion;
-- no captura excepciones (evita una subtransaccion por fila en el listado).
--   p_pk_usuario NULL  -> TRUE (llamada interna sin scoping).
--   categoria nivel 0  -> TRUE (SUPER_ADMIN, bypass; no se le exige capability).
--   sin capability VER  -> FALSE.
--   nivel 1 territorial -> TRUE (todos los EE).
--   nivel 2            -> EE del grupo en fn_usuario_ee_accesibles.
--   nivel 3            -> par (sede, jornada) del grupo en fn_usuario_sedes_jornadas_accesibles.
--   nivel 4 / sin categoria -> FALSE (fail-closed).
CREATE OR REPLACE FUNCTION academico_test.fn_matricula_puede_ver(
    p_pk_usuario  BIGINT,
    p_fk_tgrupo   BIGINT
)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_nivel INT;
BEGIN
    IF p_pk_usuario IS NULL THEN
        RETURN TRUE;
    END IF;

    v_nivel := COALESCE(academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario), 99);

    IF v_nivel = 0 THEN
        RETURN TRUE;
    END IF;

    IF NOT academico_test.fn_usuario_puede_en_menu(p_pk_usuario, 'MATRICULA', 'VER') THEN
        RETURN FALSE;
    END IF;

    IF v_nivel = 1 THEN
        RETURN TRUE;
    ELSIF v_nivel = 2 THEN
        RETURN academico_test.fn_grupo_establecimiento(p_fk_tgrupo) IN (
                   SELECT establecimiento_id
                     FROM academico_test.fn_usuario_ee_accesibles(p_pk_usuario));
    ELSIF v_nivel = 3 THEN
        RETURN (
                   academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(p_fk_tgrupo)),
                   academico_test.fn_grupo_jornada(p_fk_tgrupo)
               ) IN (
                   SELECT sede_id, jornada_id
                     FROM academico_test.fn_usuario_sedes_jornadas_accesibles(p_pk_usuario));
    END IF;

    RETURN FALSE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_matricula_puede_ver(BIGINT, BIGINT)
    IS 'Version BOOLEAN de fn_matricula_gate_escritura para el WHERE de fn_matricula_listar (V200): capability ''VER'' sobre el menu MATRICULA + scope por categoria de rol, resuelto por el grupo. p_pk_usuario NULL o SUPER_ADMIN => TRUE. Reemplaza a fn_periodo_usuario_puede_ver en el listado de matricula. No lanza (no subtransaccion por fila).';

-- ----- AREA (TAREA) --------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_area_crear(BIGINT, BIGINT, VARCHAR, VARCHAR, VARCHAR, NUMERIC, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_area_crear(
    p_fk_periodo          BIGINT,
    p_fk_area_asignatura  BIGINT,
    p_nombre_interno      VARCHAR(130),
    p_abreviacion         VARCHAR(30),   -- va a CODIGO (el front lo manda como "abreviacion")
    p_orden_reportes      NUMERIC     DEFAULT 0,
    p_pk_usuario_solicitante BIGINT   DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
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
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(a.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TAREA a WHERE a.PK_TAREA = p_pk));
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
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(a.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TAREA a WHERE a.PK_TAREA = p_pk));
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
           AND academico_test.fn_periodo_usuario_puede_ver($5, $1)
           AND ($2 IS NULL OR a.NOMBRE ILIKE '%%' || $2 || '%%')
         ORDER BY %s %s, a.NOMBRE, a.PK_TAREA
         LIMIT NULLIF($4, 0)
        OFFSET COALESCE($3, 0) * COALESCE(NULLIF($4, 0), 0)
    $q$, v_col, v_dir)
    USING p_fk_periodo, NULLIF(TRIM(p_nombre_interno),''), p_page_index, p_page_size, p_pk_usuario;
END;
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
$$;

-- ---------------------------------------------------------------------------
-- fn_enfasis_desde_seleccion — resuelve el "id" elegido en el combo combinado
-- especialidad+enfasis (fn_especialidad_enfasis_listar) a un PK_TENFASIS del
-- establecimiento dueño del periodo. La resolucion del establecimiento se hace
-- internamente (periodo -> sede -> establecimiento) para que los callers no
-- tengan que duplicar el JOIN. Reglas:
--   * p_id NULL -> NULL (sin especialidad).
--   * Si el id ya es un ENFASIS activo del establecimiento -> se usa tal cual.
--   * Si es una ESPECIALIDAD global activa -> se crea (o reusa) un enfasis del
--     establecimiento con NOMBRE y FK_TESPECIALIDAD de esa especialidad y un
--     CODIGO incremental (00000, 00001, ...) por establecimiento. Reusa el ya
--     creado (misma especialidad + nombre) si se vuelve a elegir. Devuelve su PK.
--   * Si el periodo no existe o esta inactivo -> P0002.
--   * Si no es ni una ni otra -> 22023.
-- Nota: el id de enfasis del establecimiento tiene prioridad ante colision
-- numerica con una especialidad global (el front distingue por 'origen'; si en
-- el futuro se quiere 100% inequivoco, pasar el origen como parametro).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS academico_test.fn_enfasis_desde_seleccion(BIGINT, BIGINT, VARCHAR);
CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_desde_seleccion(
    p_fk_periodo BIGINT, p_id BIGINT, p_audit VARCHAR
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_est    BIGINT;          -- establecimiento del periodo (periodo -> sede -> establecimiento)
    v_enf    BIGINT;
    v_nombre VARCHAR(130);
    v_next   INT;
BEGIN
    IF p_id IS NULL THEN RETURN NULL; END IF;
    -- Resolver establecimiento a partir del periodo (periodo -> sede -> establecimiento).
    SELECT s.FK_TESTABLECIMIENTO INTO v_est
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo AND pa.ACTIVE = TRUE;
    IF v_est IS NULL THEN
        RAISE EXCEPTION 'El periodo academico % no existe o esta inactivo', p_fk_periodo
            USING ERRCODE = 'P0002';
    END IF;
    -- 1) ¿Ya es un enfasis del establecimiento?
    SELECT PK_TENFASIS INTO v_enf FROM academico_test.TENFASIS
     WHERE PK_TENFASIS = p_id AND ACTIVE = TRUE AND FK_TESTABLECIMIENTO = v_est;
    IF v_enf IS NOT NULL THEN RETURN v_enf; END IF;
    -- 2) ¿Es una especialidad global activa? -> resolver-o-crear enfasis con su nombre.
    SELECT NOMBRE INTO v_nombre FROM academico_test.TESPECIALIDAD
     WHERE PK_ESPECIALIDAD = p_id AND ACTIVE = TRUE;
    IF v_nombre IS NULL THEN
        RAISE EXCEPTION 'La especialidad/enfasis % no existe, esta inactiva o pertenece a otro establecimiento', p_id
            USING ERRCODE = '22023';
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
$$;

-- ---------------------------------------------------------------------------
-- fn_enfasis_actualizar — edita NOMBRE/CODIGO/FK_TESPECIALIDAD de un enfasis
-- del establecimiento. No permite mover el enfasis a otro establecimiento (no
-- se recibe FK_TESTABLECIMIENTO como parametro editable).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_actualizar(
    p_pk                     BIGINT,
    p_nombre                 VARCHAR(130) DEFAULT NULL,
    p_codigo                 VARCHAR(30)  DEFAULT NULL,
    p_fk_especialidad        BIGINT       DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT       DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    r academico_test.TENFASIS;
    v_nombre VARCHAR(130); v_codigo VARCHAR(30);
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    SELECT * INTO r FROM academico_test.TENFASIS WHERE PK_TENFASIS = p_pk AND ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe un enfasis activo con PK %', p_pk USING ERRCODE = 'P0002';
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
        RAISE EXCEPTION 'La especialidad % no existe o esta inactiva', p_fk_especialidad USING ERRCODE = '23503';
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
$$;

-- ---------------------------------------------------------------------------
-- fn_enfasis_soft_delete — baja logica. Bloquea si hay asignaturas activas
-- usando el enfasis (evita dejar TASIGNATURA.FK_TENFASIS apuntando a un enfasis
-- inactivo).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_enfasis_soft_delete(
    p_pk BIGINT, p_pk_usuario_solicitante BIGINT
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_est BIGINT; v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    SELECT FK_TESTABLECIMIENTO INTO v_est FROM academico_test.TENFASIS
     WHERE PK_TENFASIS = p_pk AND ACTIVE = TRUE;
    IF v_est IS NULL THEN
        RAISE EXCEPTION 'No existe un enfasis activo con PK %', p_pk USING ERRCODE = 'P0002';
    END IF;
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, v_est);
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA s WHERE s.FK_TENFASIS = p_pk AND s.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar el enfasis %: existen asignaturas asociadas', p_pk
            USING ERRCODE = '23503';
    END IF;
    UPDATE academico_test.TENFASIS SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TENFASIS = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'No existe un enfasis activo con PK %', p_pk USING ERRCODE = 'P0002';
    END IF;
    RETURN p_pk;
END;
$$;

-- ----- ASIGNATURA (TASIGNATURA) — "abreviacion" del front = CODIGO ----------
CREATE OR REPLACE FUNCTION academico_test.fn_subject_crear(
    p_fk_area             BIGINT,
    p_fk_area_asignatura  BIGINT,
    p_nombre_interno      VARCHAR(130),
    p_abreviacion         VARCHAR(30),               -- va a CODIGO
    p_fk_enfasis          BIGINT      DEFAULT 2,
    p_color               VARCHAR(10) DEFAULT NULL,
    p_orden_reportes      NUMERIC     DEFAULT 0,
    p_pk_usuario_solicitante BIGINT   DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_est BIGINT; v_periodo BIGINT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
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
    v_nombre VARCHAR(130); v_codigo VARCHAR(30); v_enfasis BIGINT; v_est BIGINT; v_periodo BIGINT;
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(a.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TASIGNATURA s JOIN academico_test.TAREA a ON a.PK_TAREA = s.FK_TAREA
         WHERE s.PK_TASIGNATURA = p_pk));
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
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_subject_soft_delete(p_pk BIGINT, p_pk_usuario_solicitante BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_n INT; v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(p_pk_usuario_solicitante, (
        SELECT academico_test.fn_periodo_establecimiento(a.FK_TPERIODO_ACADEMICO)
          FROM academico_test.TASIGNATURA s JOIN academico_test.TAREA a ON a.PK_TAREA = s.FK_TAREA
         WHERE s.PK_TASIGNATURA = p_pk));
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
    -- Procesos academicos activos: ya hay calificaciones registradas para la asignatura.
    IF EXISTS (
        SELECT 1 FROM academico_test.TASIGNATURA_NOTA an
         WHERE an.FK_TASIGNATURA = p_pk AND an.ACTIVE = TRUE
    ) THEN
        RAISE EXCEPTION 'No se puede eliminar la asignatura %: existen calificaciones registradas', p_pk
            USING ERRCODE = '23503';
    END IF;
    UPDATE academico_test.TASIGNATURA SET ACTIVE = FALSE, MODIFIED_BY = v_audit, MODIFIED_AT = CURRENT_TIMESTAMP
     WHERE PK_TASIGNATURA = p_pk AND ACTIVE = TRUE;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN RAISE EXCEPTION 'No existe una asignatura activa con PK %', p_pk USING ERRCODE = 'P0002'; END IF;
    RETURN p_pk;
END;
$$;

-- La 2-arg tambien se dropea: V103 la redefine con una columna extra en el
-- RETURNS TABLE, y sin este DROP re-ejecutar V40 (paso de re-aplicacion de
-- deploy-test.yml al cambiar el checksum de este archivo) fallaba con
-- "cannot change return type of existing function". CU-86e2w4xdt.
DROP FUNCTION IF EXISTS academico_test.fn_subject_listar(BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_subject_listar(BIGINT, BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_subject_listar(
    p_fk_area BIGINT, p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, abreviacion VARCHAR, nombre_interno VARCHAR,
               asignatura_general_id BIGINT, enfasis_id BIGINT, color VARCHAR, orden_reportes NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT s.PK_TASIGNATURA, s.CODIGO, s.NOMBRE, s.FK_TAREA_ASIGNATURA, s.FK_TENFASIS,
           s.COLOR, s.ORDEN_REPORTE
      FROM academico_test.TASIGNATURA s
     WHERE s.FK_TAREA = p_fk_area AND s.ACTIVE = TRUE
     ORDER BY s.ORDEN_REPORTE;
$$;

-- ---------------------------------------------------------------------------
-- fn_subject_periodo_listar — todas las asignaturas de un periodo academico
-- (join TASIGNATURA -> TAREA), en formato plano paginado y con sorting, igual
-- al patron de fn_periodo_listar (V37): whitelist de columnas + EXECUTE format.
-- A diferencia de fn_subject_listar (una sola area) y de
-- fn_periodo_areas_asignaturas_listar (anidado en JSON, sin filtro/paginado).
-- ---------------------------------------------------------------------------
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
               asignatura_general_id BIGINT, enfasis_id BIGINT, color VARCHAR,
               orden_reportes NUMERIC, total_count BIGINT)
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
               s.FK_TAREA_ASIGNATURA, s.FK_TENFASIS, s.COLOR, s.ORDEN_REPORTE,
               count(*) OVER()::BIGINT
          FROM academico_test.TASIGNATURA s
          JOIN academico_test.TAREA a ON a.PK_TAREA = s.FK_TAREA AND a.ACTIVE = TRUE
         WHERE a.FK_TPERIODO_ACADEMICO = $1 AND s.ACTIVE = TRUE
           AND academico_test.fn_periodo_usuario_puede_ver($5, $1)
           AND ($2 IS NULL OR s.NOMBRE ILIKE '%%' || $2 || '%%' OR s.CODIGO ILIKE '%%' || $2 || '%%')
         ORDER BY %s %s, s.NOMBRE, s.PK_TASIGNATURA
         LIMIT NULLIF($4, 0)
        OFFSET COALESCE($3, 0) * COALESCE(NULLIF($4, 0), 0)
    $q$, v_col, v_dir)
    USING p_fk_periodo, NULLIF(TRIM(p_filtro),''), p_page_index, p_page_size, p_pk_usuario;
END;
$$;

-- ----- CATALOGOS PARA SELECTS ----------------------------------------------
-- Areas/asignaturas generales (TAREA_ASIGNATURA) para el select de "area general".
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

-- Areas de un periodo con sus asignaturas anidadas, para el selector de
-- asignaturas/areas obligatorias del criterio de promocion (V39). Una fila por
-- area; `asignaturas` es un arreglo jsonb (vacio si el area no tiene ninguna).
-- Limpieza del nombre previo (version plana) por si ya se aplico en test.
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
     ORDER BY a.ORDEN_REPORTE, a.NOMBRE;
$$;

-- Especialidades (catalogo global) + enfasis del establecimiento, en una sola
-- lista con un campo 'origen' para distinguirlos.
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
     ORDER BY 4, 2;
$$;

-- ----- ASIGNATURAS EN LOTE (set completo del area) --------------------------
-- p_asignaturas jsonb = set COMPLETO de asignaturas del area, en el shape del
-- front: [{nombreInterno, abreviacion, asignaturaGeneral, especialidad?, color?,
-- ordenReportes?}]. Semantica de REEMPLAZO: da de baja las que ya no estan
-- (por nombre) y hace upsert por nombre de las presentes. `asignaturaGeneral`
-- llega como ID (fk_area_asignatura). `especialidad` llega como NOMBRE: si es una
-- especialidad global se resuelve-o-crea como enfasis (FK_TESPECIALIDAD real +
-- codigo incremental); si es un nombre nuevo, se crea enfasis con especialidad "Otro".
CREATE OR REPLACE FUNCTION academico_test.fn_subject_guardar_bulk(
    p_fk_area             BIGINT,
    p_asignaturas         jsonb,
    p_pk_usuario_solicitante BIGINT
)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_audit VARCHAR(120) := p_pk_usuario_solicitante::VARCHAR;
    v_est BIGINT; v_periodo BIGINT; v_count INT := 0; it jsonb;
    v_id BIGINT; v_nombre VARCHAR(130); v_codigo VARCHAR(30);
    v_aa BIGINT; v_enf BIGINT; v_esp BIGINT; v_color VARCHAR(10); v_orden NUMERIC;
    v_enf_name TEXT;
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
        RAISE EXCEPTION 'El area % no existe o esta inactiva', p_fk_area USING ERRCODE = '23503';
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
            RAISE EXCEPTION 'La asignatura general % no existe o esta inactiva', v_aa USING ERRCODE = '23503';
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
