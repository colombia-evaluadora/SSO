-- ===========================================================================
-- V37.3 -- Periodo academico: wrappers de los endpoints
-- ===========================================================================
-- QUE HACE: las funciones que llaman los endpoints de V75 y los selects de
-- los filtros (antes en V191). Cada escritura:
-- existencia (P0002) -> estado (22023) -> gate con el alcance (EE, sede,
-- jornada) del periodo -> fn_audit_declarar si escribe -> delegar en V37.2.
-- Las firmas no cambian: las filas de public.query siguen igual.
-- POR QUE AQUI: capa 3 del modulo (V37.1 / V37.2 / V37.3).
-- DEPENDE DE: V29 (gates, alcance), V37.1, V37.2; en ejecucion V66 (auditoria).
-- ===========================================================================

SET search_path TO academico_test, public;

-- Sin periodo aun: el alcance sale de la sede elegida, asi que antes del gate
-- con alcance se exige que la sede exista (y los campos, para nombrar el fallo).
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_crear(
    p_fk_sede BIGINT,
    p_fk_estado BIGINT,
    p_fecha_inicio DATE,
    p_fecha_fin DATE,
    p_fecha_limite_matricula DATE,
    p_fk_jornada BIGINT,
    p_hora_inicio TIME,
    p_hora_fin TIME,
    p_reserva academico_test.bool_sn DEFAULT 'S',
    p_bloques_por_defecto BIGINT DEFAULT 0,
    p_fk_periodo_anterior BIGINT DEFAULT NULL,
    p_descanso_inicio TIME[] DEFAULT NULL,
    p_descanso_fin TIME[] DEFAULT NULL,
    p_pk_usuario_solicitante BIGINT DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_est BIGINT; v_nombre_sede VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, NULL, NULL, NULL, 'CREAR');
    PERFORM academico_test.fn_periodo_validar_campos(p_fk_sede, p_fk_estado, p_fecha_inicio, p_fecha_fin,
        p_fecha_limite_matricula, p_fk_jornada, p_hora_inicio, p_hora_fin);
    PERFORM academico_test.fn_periodo_validar_sede(p_fk_sede);
    SELECT FK_TESTABLECIMIENTO, NOMBRE INTO v_est, v_nombre_sede
      FROM academico_test.TSEDE WHERE PK_TSEDE = p_fk_sede;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est, p_fk_sede, p_fk_jornada, 'CREAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Creación del periodo académico %s - %s en la sede %s', to_char(p_fecha_inicio, 'YYYY'),
            (SELECT VALOR FROM academico_test.TLISTA_VALOR WHERE PK_LISTA_VALOR = p_fk_jornada), v_nombre_sede),
        v_est);
    RETURN academico_test.fn_periodo_crear_interno(p_fk_sede, p_fk_estado, p_fecha_inicio, p_fecha_fin,
        p_fecha_limite_matricula, p_fk_jornada, p_hora_inicio, p_hora_fin, p_reserva, p_bloques_por_defecto,
        p_fk_periodo_anterior, p_descanso_inicio, p_descanso_fin, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_crear(BIGINT, BIGINT, DATE, DATE, DATE, BIGINT, TIME, TIME, academico_test.bool_sn, BIGINT, BIGINT, TIME[], TIME[], BIGINT)
    IS 'POST /periodos-academicos. Gate CREAR sobre PERIODOS_ACADEMICOS con el alcance de la sede y jornada elegidas; delega en fn_periodo_crear_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_actualizar(
    p_pk_periodo              BIGINT,
    p_fk_estado               BIGINT   DEFAULT NULL,
    p_fk_sede                 BIGINT   DEFAULT NULL,
    p_fecha_inicio            DATE     DEFAULT NULL,
    p_fecha_fin               DATE     DEFAULT NULL,
    p_fecha_limite_matricula  DATE     DEFAULT NULL,
    p_fk_jornada              BIGINT   DEFAULT NULL,
    p_reserva                 academico_test.bool_sn DEFAULT NULL,
    p_bloques_por_defecto     BIGINT   DEFAULT NULL,
    p_fk_periodo_anterior     BIGINT   DEFAULT NULL,
    p_hora_inicio             TIME     DEFAULT NULL,
    p_hora_fin                TIME     DEFAULT NULL,
    p_descanso_inicio         TIME[]   DEFAULT NULL,
    p_descanso_fin            TIME[]   DEFAULT NULL,
    p_pk_usuario_solicitante  BIGINT   DEFAULT NULL
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    r             academico_test.TPERIODO_ACADEMICO;
    v_sede        BIGINT;
    v_est_new     BIGINT;
    v_nombre_sede VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_validar_existe(p_pk_periodo);
    PERFORM academico_test.fn_periodo_validar_activo(p_pk_periodo);
    SELECT * INTO r FROM academico_test.TPERIODO_ACADEMICO WHERE PK_TPERIODO_ACADEMICO = p_pk_periodo;
    -- El alcance es el del periodo tal como esta, no el de la sede destino.
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, academico_test.fn_periodo_establecimiento(p_pk_periodo),
        r.FK_TSEDE, r.FK_TLV_JORNADA, 'EDITAR');

    v_sede := COALESCE(p_fk_sede, r.FK_TSEDE);
    SELECT FK_TESTABLECIMIENTO, NOMBRE INTO v_est_new, v_nombre_sede
      FROM academico_test.TSEDE WHERE PK_TSEDE = v_sede;
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Actualización del periodo académico %s - %s en la sede %s',
            to_char(COALESCE(p_fecha_inicio, r.FECHA_INICIO), 'YYYY'),
            (SELECT VALOR FROM academico_test.TLISTA_VALOR
              WHERE PK_LISTA_VALOR = COALESCE(p_fk_jornada, r.FK_TLV_JORNADA)),
            v_nombre_sede),
        v_est_new);
    RETURN academico_test.fn_periodo_actualizar_interno(p_pk_periodo, p_fk_estado, p_fk_sede, p_fecha_inicio,
        p_fecha_fin, p_fecha_limite_matricula, p_fk_jornada, p_reserva, p_bloques_por_defecto,
        p_fk_periodo_anterior, p_hora_inicio, p_hora_fin, p_descanso_inicio, p_descanso_fin,
        p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_actualizar(BIGINT, BIGINT, BIGINT, DATE, DATE, DATE, BIGINT, academico_test.bool_sn, BIGINT, BIGINT, TIME, TIME, TIME[], TIME[], BIGINT)
    IS 'PUT /periodos-academicos/editar/:ID. Gate EDITAR con el alcance actual del periodo; delega en fn_periodo_actualizar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_soft_delete(p_pk_periodo BIGINT, p_pk_usuario_solicitante BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_activo  BOOLEAN;
    v_nombre  VARCHAR(200);
    v_est     BIGINT;
    v_sede    BIGINT;
    v_jornada BIGINT;
BEGIN
    PERFORM academico_test.fn_periodo_validar_existe(p_pk_periodo);
    -- Con sede en la etiqueta: puede haber un periodo activo por jornada en el mismo año y sede.
    SELECT pa.ACTIVE, s.NOMBRE || ' - ' || al.NOMBRE || ' - ' || jor.NOMBRE,
           s.FK_TESTABLECIMIENTO, pa.FK_TSEDE, pa.FK_TLV_JORNADA
      INTO v_activo, v_nombre, v_est, v_sede, v_jornada
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s          ON s.PK_TSEDE = pa.FK_TSEDE
      JOIN academico_test.TANO_LECTIVO al  ON al.PK_ANO_LECTIVO = pa.FK_TANO_LECTIVO
      JOIN academico_test.TLISTA_VALOR jor ON jor.PK_LISTA_VALOR = pa.FK_TLV_JORNADA
     WHERE pa.PK_TPERIODO_ACADEMICO = p_pk_periodo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el periodo academico' USING ERRCODE = 'P0002';
    END IF;
    IF v_activo = FALSE THEN
        RAISE EXCEPTION 'El periodo academico "%" ya esta inactivo', v_nombre USING ERRCODE = '22023';
    END IF;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est, v_sede, v_jornada, 'ELIMINAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación del periodo académico %s', v_nombre), v_est);
    RETURN academico_test.fn_periodo_eliminar_interno(p_pk_periodo, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_soft_delete(BIGINT, BIGINT)
    IS 'PUT /periodos-academicos/:ID. Gate ELIMINAR con el alcance del periodo; las dependencias (23503) se miran despues del gate en fn_periodo_eliminar_interno.';

-- Cada id se gatea con su propio alcance dentro de fn_periodo_soft_delete.
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_bulk_delete(
    p_ids BIGINT[], p_pk_usuario_solicitante BIGINT
)
RETURNS TABLE (id BIGINT, eliminado BOOLEAN, error_code TEXT, error_mensaje TEXT)
LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT; v_state TEXT; v_msg TEXT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PERIODOS_ACADEMICOS', 'ELIMINAR');
    IF p_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY p_ids LOOP
        BEGIN
            PERFORM academico_test.fn_periodo_soft_delete(v_id, p_pk_usuario_solicitante);
            id := v_id; eliminado := TRUE; error_code := NULL; error_mensaje := NULL;
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
            id := v_id; eliminado := FALSE; error_code := v_state; error_mensaje := v_msg;
            RETURN NEXT;
        END;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_bulk_delete(BIGINT[], BIGINT)
    IS 'PUT /periodos-academicos. Un resultado por id; los errores no cortan el lote.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_detalle(
    p_pk_periodo BIGINT,
    p_pk_usuario BIGINT DEFAULT NULL
)
RETURNS TABLE(
    id BIGINT, sede_id BIGINT, sede_name VARCHAR, school_year_id BIGINT,
    school_year_name VARCHAR, status_id BIGINT, status VARCHAR, status_name VARCHAR,
    start_date DATE, end_date DATE, enrollment_deadline DATE, name VARCHAR,
    jornada_id BIGINT, jornada VARCHAR, jornada_name VARCHAR,
    reserva academico_test.bool_sn, default_blocks_count BIGINT,
    schedule_start_time TIME, schedule_end_time TIME, descansos JSONB,
    previous_period_id BIGINT
)
LANGUAGE sql STABLE AS $$
    SELECT d.*
      FROM academico_test.fn_periodo_detalle_interno(p_pk_periodo) d
     WHERE academico_test.fn_periodo_puede_ver(p_pk_usuario, p_pk_periodo);
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_detalle(BIGINT, BIGINT)
    IS 'GET /periodos-academicos/:ID. Vacio si no existe, esta inactivo o el usuario no lo alcanza.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_listar(
    p_fk_sede      BIGINT   DEFAULT NULL,
    p_nombre_sede  TEXT     DEFAULT NULL,
    p_ano          TEXT     DEFAULT NULL,
    p_fk_estado    BIGINT   DEFAULT NULL,
    p_fecha_desde  DATE     DEFAULT NULL,
    p_fecha_hasta  DATE     DEFAULT NULL,
    p_pk_usuario   BIGINT   DEFAULT NULL,
    p_page_index   INT      DEFAULT 0,
    p_page_size    INT      DEFAULT 10,
    p_sort_by      TEXT     DEFAULT NULL,
    p_sort_dir     TEXT     DEFAULT NULL
)
RETURNS TABLE (
    id BIGINT, sede_id BIGINT, sede_name VARCHAR, school_year_id BIGINT,
    school_year_name VARCHAR, status_id BIGINT, status VARCHAR, status_name VARCHAR,
    start_date DATE, end_date DATE, enrollment_deadline DATE, name VARCHAR,
    jornada_id BIGINT, jornada VARCHAR, jornada_name VARCHAR,
    reserva academico_test.bool_sn, default_blocks_count BIGINT,
    schedule_start_time TIME, schedule_end_time TIME, descansos JSONB,
    previous_period_id BIGINT, previous_period_name VARCHAR, total_count BIGINT
)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_periodos BIGINT[];
BEGIN
    -- Alcance resuelto antes de paginar para que total_count cuente solo lo
    -- visible. Sin usuario no se filtra (fn_periodo_puede_ver(NULL) = TRUE);
    -- el COALESCE evita que "ninguno visible" (array_agg NULL) se lea como "todos".
    IF p_pk_usuario IS NOT NULL THEN
        SELECT COALESCE(array_agg(pa.PK_TPERIODO_ACADEMICO), '{}') INTO v_periodos
          FROM academico_test.TPERIODO_ACADEMICO pa
         WHERE pa.ACTIVE = TRUE
           AND (p_fk_sede IS NULL OR pa.FK_TSEDE = p_fk_sede)
           AND academico_test.fn_periodo_puede_ver(p_pk_usuario, pa.PK_TPERIODO_ACADEMICO);
    END IF;
    RETURN QUERY SELECT * FROM academico_test.fn_periodo_listar_interno(
        v_periodos, p_fk_sede, p_nombre_sede, p_ano, p_fk_estado, p_fecha_desde, p_fecha_hasta,
        p_page_index, p_page_size, p_sort_by, p_sort_dir);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_listar(BIGINT, TEXT, TEXT, BIGINT, DATE, DATE, BIGINT, INT, INT, TEXT, TEXT)
    IS 'POST /periodos-academicos/query y /periodos-academicos/reporte. Solo los periodos que el usuario alcanza (fn_periodo_puede_ver); delega en fn_periodo_listar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_anteriores_por_sede(
    p_fk_sede          BIGINT,
    p_excluir_periodo  BIGINT DEFAULT NULL,
    p_pk_usuario       BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, name VARCHAR, start_date DATE)
LANGUAGE sql STABLE AS $$
    SELECT a.*
      FROM academico_test.fn_periodo_anteriores_por_sede_interno(p_fk_sede, p_excluir_periodo) a
     WHERE academico_test.fn_periodo_puede_ver(p_pk_usuario, a.id)
     ORDER BY a.start_date DESC;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_anteriores_por_sede(BIGINT, BIGINT, BIGINT)
    IS 'POST /periodos-academicos/anterior y /periodos-evaluacion/anterior. Solo los periodos que el usuario alcanza; delega en fn_periodo_anteriores_por_sede_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_descanso_agregar(
    p_fk_periodo BIGINT, p_hora_inicio TIME, p_hora_fin TIME, p_pk_usuario_solicitante BIGINT
)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_est BIGINT; v_nombre_sede VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_periodo_validar_existe(p_fk_periodo);
    SELECT s.FK_TESTABLECIMIENTO, s.NOMBRE INTO v_est, v_nombre_sede
      FROM academico_test.TPERIODO_ACADEMICO pa
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE pa.PK_TPERIODO_ACADEMICO = p_fk_periodo;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est,
        academico_test.fn_periodo_sede(p_fk_periodo),
        academico_test.fn_periodo_jornada(p_fk_periodo), 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Agregado de descanso %s-%s al periodo académico de la sede %s', p_hora_inicio, p_hora_fin, v_nombre_sede),
        v_est);
    RETURN academico_test.fn_descanso_agregar_interno(p_fk_periodo, p_hora_inicio, p_hora_fin,
        p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_descanso_agregar(BIGINT, TIME, TIME, BIGINT)
    IS 'POST /periodos-academicos/:ID/descansos. Gate EDITAR con el alcance del periodo; delega en fn_descanso_agregar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_descanso_eliminar(p_pk_descanso BIGINT, p_pk_usuario_solicitante BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_est         BIGINT;
    v_sede        BIGINT;
    v_jornada     BIGINT;
    v_nombre_sede VARCHAR(130);
    v_hi          TIME;
    v_hf          TIME;
BEGIN
    PERFORM academico_test.fn_descanso_validar_existe(p_pk_descanso);
    SELECT s.FK_TESTABLECIMIENTO, pa.FK_TSEDE, pa.FK_TLV_JORNADA, s.NOMBRE, d.HORA_INICIO, d.HORA_FIN
      INTO v_est, v_sede, v_jornada, v_nombre_sede, v_hi, v_hf
      FROM academico_test.TDESCANSOS d
      JOIN academico_test.TPERIODO_ACADEMICO pa ON pa.PK_TPERIODO_ACADEMICO = d.FK_TPERIODO_ACADEMICO
      JOIN academico_test.TSEDE s ON s.PK_TSEDE = pa.FK_TSEDE
     WHERE d.PK_TDESCANSOS = p_pk_descanso;
    PERFORM academico_test.fn_periodo_gate_escritura(
        p_pk_usuario_solicitante, v_est, v_sede, v_jornada, 'EDITAR');
    PERFORM academico_test.fn_audit_declarar(p_pk_usuario_solicitante,
        format('Eliminación del descanso %s-%s de la sede %s', v_hi, v_hf, v_nombre_sede), v_est);
    RETURN academico_test.fn_descanso_eliminar_interno(p_pk_descanso, p_pk_usuario_solicitante::VARCHAR);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_descanso_eliminar(BIGINT, BIGINT)
    IS 'PUT /periodos-academicos/descansos/:ID. Gate EDITAR con el alcance del periodo del descanso; delega en fn_descanso_eliminar_interno.';

-- ------------------------------------------------- selects de los filtros
-- El alcance (global / establecimientos / sedes del usuario) se calcula una
-- vez aqui y viaja al nucleo como arrays.

-- Firmas viejas de un parametro que quedaron en servidores antiguos.
DROP FUNCTION IF EXISTS academico_test.fn_periodo_anos_lectivos_listar(BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_anos_lectivos_listar(
    p_pk_usuario BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, name VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT * FROM academico_test.fn_periodo_anos_lectivos_listar_interno(
        academico_test.fn_periodo_usuario_global(p_pk_usuario),
        ARRAY(SELECT establecimiento_id FROM academico_test.fn_periodo_usuario_establecimientos(p_pk_usuario)),
        ARRAY(SELECT sede_id FROM academico_test.fn_periodo_usuario_sedes(p_pk_usuario)));
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_anos_lectivos_listar(BIGINT)
    IS 'GET /periodos-academicos/anos-lectivos. Años lectivos del año en curso dentro del alcance del usuario; delega en fn_periodo_anos_lectivos_listar_interno.';

DROP FUNCTION IF EXISTS academico_test.fn_periodo_jornadas_listar(BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_jornadas_listar(
    p_pk_usuario BIGINT DEFAULT NULL,
    p_fk_sede BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, name VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT * FROM academico_test.fn_periodo_jornadas_listar_interno(
        p_fk_sede,
        academico_test.fn_periodo_usuario_global(p_pk_usuario),
        ARRAY(SELECT establecimiento_id FROM academico_test.fn_periodo_usuario_establecimientos(p_pk_usuario)),
        ARRAY(SELECT sede_id FROM academico_test.fn_periodo_usuario_sedes(p_pk_usuario)));
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_jornadas_listar(BIGINT, BIGINT)
    IS 'Select de jornadas del filtro de periodos academicos (sin fila en public.query en el repo). Jornadas con periodo activo dentro del alcance del usuario; delega en fn_periodo_jornadas_listar_interno.';

DROP FUNCTION IF EXISTS academico_test.fn_periodo_sedes_listar(BIGINT);
CREATE OR REPLACE FUNCTION academico_test.fn_periodo_sedes_listar(
    p_pk_usuario BIGINT DEFAULT NULL
)
RETURNS TABLE (id BIGINT, name VARCHAR)
LANGUAGE sql STABLE AS $$
    SELECT * FROM academico_test.fn_periodo_sedes_listar_interno(
        academico_test.fn_periodo_usuario_global(p_pk_usuario),
        ARRAY(SELECT establecimiento_id FROM academico_test.fn_periodo_usuario_establecimientos(p_pk_usuario)),
        ARRAY(SELECT sede_id FROM academico_test.fn_periodo_usuario_sedes(p_pk_usuario)));
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_sedes_listar(BIGINT)
    IS 'Select de sedes del filtro de periodos academicos (sin fila en public.query en el repo). Sedes con periodo activo dentro del alcance del usuario; delega en fn_periodo_sedes_listar_interno.';
