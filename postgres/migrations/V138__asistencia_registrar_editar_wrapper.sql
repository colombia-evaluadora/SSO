-- ===========================================================================
-- V138 -- fn_asistencia_registrar_bulk / fn_asistencia_editar como WRAPPER:
-- gate + validaciones (V136) + etiqueta de auditoria + nucleo _interno (V137).
-- Reglas: docente asignado a la asignatura (74), dia de clase programado
-- (72c), excusa solo en inasistencia o tardanza (72b) y, con el periodo de
-- evaluacion ya no calificable, la edicion queda como solicitud del
-- Coordinador (75). Incluye fn_asistencia_gate_escritura (antes V220).
-- Depende de: V136, V137, V22, V29 (fn_assert_permiso_seccion), V40, V66
-- (fn_audit_declarar), V496.18-V496.19 (aprobacion; enlace tardio).
-- ===========================================================================

SET search_path TO academico_test, public;

-- Definicion sin cambios respecto a la V220 original (eliminada).
CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_gate_escritura(
    p_pk_usuario  BIGINT,
    p_fk_tgrupo   BIGINT,
    p_accion      VARCHAR DEFAULT 'EDITAR'
)
RETURNS VOID LANGUAGE plpgsql STABLE AS $$
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario, 'ASISTENCIAS', p_accion,
        academico_test.fn_grupo_establecimiento(p_fk_tgrupo),
        academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(p_fk_tgrupo)),
        academico_test.fn_grupo_jornada(p_fk_tgrupo));
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_gate_escritura(BIGINT, BIGINT, VARCHAR)
    IS 'Adaptador de seccion == fn_matricula_gate_escritura (V40) con el menu ''ASISTENCIAS''. Delega 1:1 en fn_assert_permiso_seccion (V29): CAPABILITY + SCOPE por categoria de rol resuelto por el grupo + BYPASS del SUPER_ADMIN. Lanza 42501 (-> HTTP 403). Copia identica de V220, redefinida aqui (V138) para trazabilidad -- la usan fn_asistencia_registrar_bulk y fn_asistencia_editar.';

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_registrar_bulk(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fecha                  DATE,
    p_bloque                 NUMERIC DEFAULT NULL,
    p_registros              JSONB   DEFAULT NULL,
    p_marcar_todos_valor     NUMERIC DEFAULT NULL,
    p_fk_tactividad          BIGINT  DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_nombre_grupo VARCHAR(130);
BEGIN
    PERFORM academico_test.fn_asistencia_gate_escritura(
        p_pk_usuario_solicitante, p_fk_tgrupo, 'CREAR');

    PERFORM academico_test.fn_asistencia_validar_fecha_no_futura(p_fecha);
    PERFORM academico_test.fn_asistencia_validar_contexto(
        p_fk_tgrupo, p_fk_tasignatura, p_fk_tactividad);
    PERFORM academico_test.fn_asistencia_validar_periodo_abierto(p_fk_tgrupo, 'registrar');
    PERFORM academico_test.fn_asistencia_validar_docente_asignado(
        p_pk_usuario_solicitante, p_fk_tgrupo, p_fk_tasignatura, p_fk_tactividad);
    PERFORM academico_test.fn_asistencia_validar_fecha_programada(
        p_fk_tgrupo, p_fk_tasignatura, p_fecha, p_bloque);
    PERFORM academico_test.fn_asistencia_validar_excusa_registros(p_registros, p_marcar_todos_valor);

    SELECT NOMBRE INTO v_nombre_grupo FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_fk_tgrupo;
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format(CASE WHEN COALESCE(academico_test.fn_asistencia_fecha_requiere_aprobacion(p_fk_tgrupo, p_fecha), FALSE)
                    THEN 'Solicitud de correccion de asistencia del grupo %s (%s)'
                    ELSE 'Registro de asistencia del grupo %s (%s)' END,
               v_nombre_grupo, p_fecha),
        academico_test.fn_grupo_establecimiento(p_fk_tgrupo),
        academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(p_fk_tgrupo)));

    RETURN academico_test.fn_asistencia_registrar_bulk_interno(
        p_fk_tgrupo, p_fk_tasignatura, p_fecha, p_bloque,
        p_registros, p_marcar_todos_valor, p_fk_tactividad,
        p_pk_usuario_solicitante);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_registrar_bulk(BIGINT, BIGINT, BIGINT, DATE, NUMERIC, JSONB, NUMERIC, BIGINT)
    IS 'POST /asistencias/registrar. WRAPPER: 1) fn_asistencia_gate_escritura, 2) fecha no futura, contexto, periodo abierto, docente asignado (Regla 74), día de clase programado (72c) y excusa solo en inasistencia o tardanza (72b), 3) etiqueta de auditoría y fn_asistencia_registrar_bulk_interno. En un periodo de evaluación no calificable no escribe: corregir o capturar tarde abre solicitudes CORRECCION_ASISTENCIA (Regla 75), que el endpoint devuelve en solicitudes_pendientes.';

CREATE OR REPLACE FUNCTION academico_test.fn_asistencia_editar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tasistencia         BIGINT,
    p_tipo_asistencia_valor  NUMERIC   DEFAULT NULL,
    p_observacion            VARCHAR   DEFAULT NULL,
    p_fk_soporte_archivo     BIGINT    DEFAULT NULL,
    p_limpiar_archivo        BOOLEAN   DEFAULT FALSE,
    p_limpiar_observacion    BOOLEAN   DEFAULT FALSE
)
RETURNS BIGINT
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_fk_tgrupo      BIGINT;
    v_fk_tasignatura BIGINT;
    v_fk_tactividad  BIGINT;
    v_fk_tmatricula  BIGINT;
    v_tipo_actual    NUMERIC;
    v_archivo_actual BIGINT;
    v_nombre_grupo   VARCHAR(130);
    v_requiere       BOOLEAN;
BEGIN
    SELECT m.FK_TGRUPO, a.FK_TASIGNATURA, a.FK_TACTIVIDAD, a.FK_TMATRICULA, a.FK_SOPORTE_ARCHIVO,
           CASE WHEN lv.VALOR ~ '^\d+$' THEN lv.VALOR::NUMERIC END
      INTO v_fk_tgrupo, v_fk_tasignatura, v_fk_tactividad, v_fk_tmatricula, v_archivo_actual, v_tipo_actual
      FROM academico_test.TASISTENCIA a
      JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = a.FK_TMATRICULA
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = a.FK_TLV_TIPO_ASISTENCIA
     WHERE a.PK_TASISTENCIA = p_pk_tasistencia AND a.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'registro de asistencia (%) no existe o no esta activo', p_pk_tasistencia
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_asistencia_gate_escritura(
        p_pk_usuario_solicitante, v_fk_tgrupo, 'EDITAR');

    -- Sin periodo de evaluación para la fecha queda el bloqueo plano por el
    -- periodo académico cerrado (V136).
    v_requiere := academico_test.fn_asistencia_correccion_requiere_aprobacion(p_pk_tasistencia);
    IF v_requiere IS NULL THEN
        PERFORM academico_test.fn_asistencia_validar_periodo_abierto(v_fk_tgrupo, 'editar');
    END IF;
    PERFORM academico_test.fn_asistencia_validar_docente_asignado(
        p_pk_usuario_solicitante, v_fk_tgrupo, v_fk_tasignatura, v_fk_tactividad);
    IF p_tipo_asistencia_valor IS NOT NULL OR p_fk_soporte_archivo IS NOT NULL THEN
        PERFORM academico_test.fn_asistencia_validar_excusa_tipo(
            COALESCE(p_tipo_asistencia_valor, v_tipo_actual),
            CASE WHEN p_limpiar_archivo THEN NULL ELSE COALESCE(p_fk_soporte_archivo, v_archivo_actual) END,
            v_fk_tmatricula);
    END IF;

    SELECT NOMBRE INTO v_nombre_grupo FROM academico_test.TGRUPO WHERE PK_TGRUPO = v_fk_tgrupo;
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format(CASE WHEN v_requiere THEN 'Solicitud de correccion de asistencia (registro %s) del grupo %s'
                    ELSE 'Edicion de asistencia (registro %s) del grupo %s' END,
               p_pk_tasistencia, v_nombre_grupo),
        academico_test.fn_grupo_establecimiento(v_fk_tgrupo),
        academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(v_fk_tgrupo)));

    IF v_requiere THEN
        RETURN academico_test.fn_asistencia_correccion_solicitar_interno(
            p_pk_usuario_solicitante, p_pk_tasistencia, p_tipo_asistencia_valor, p_observacion,
            p_fk_soporte_archivo, p_limpiar_archivo, p_limpiar_observacion);
    END IF;

    RETURN academico_test.fn_asistencia_editar_interno(
        p_pk_tasistencia, v_fk_tgrupo, p_tipo_asistencia_valor, p_observacion,
        p_fk_soporte_archivo, p_limpiar_archivo, p_limpiar_observacion,
        p_pk_usuario_solicitante);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_editar(BIGINT, BIGINT, NUMERIC, VARCHAR, BIGINT, BOOLEAN, BOOLEAN)
    IS 'PATCH /asistencias/:ID: edita un registro de asistencia (estado, observación, soporte). Con el periodo de evaluación de la fecha Calificable se aplica; si ya no lo es, queda como solicitud CORRECCION_ASISTENCIA para el Coordinador (Regla 75) y el registro no cambia; si la fecha no cae en ningún periodo de evaluación, 22023 cuando el periodo académico está Cerrado. Devuelve el PK del registro.';
