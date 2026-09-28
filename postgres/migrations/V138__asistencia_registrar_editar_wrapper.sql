-- ===========================================================================
-- V138 -- fn_asistencia_registrar_bulk / fn_asistencia_editar pasan a WRAPPER:
-- gate + validaciones (V136) + etiqueta de auditoria + nucleo _interno (V137).
-- Firmas intactas (CREATE OR REPLACE, sin DROP), reemplazan lo que definian
-- V464 y V220 (ambas eliminadas: su contenido quedo consolidado en V136-V141).
-- Suma fn_asistencia_validar_docente_asignado: antes el gate solo validaba
-- capability + alcance territorial, asi que un docente podia escribir
-- cualquier asignatura de su sede+jornada, no solo la que dicta (Regla 74).
-- Incluye fn_asistencia_gate_escritura, que vivia solo en V220.
-- Depende de: V136, V137, TGRUPO/TASISTENCIA/TMATRICULA (V22), V29
-- (fn_assert_permiso_seccion), V40 (fn_grupo_establecimiento/_periodo/_jornada,
-- fn_periodo_sede), V66 (fn_audit_declarar).
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

    SELECT NOMBRE INTO v_nombre_grupo FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_fk_tgrupo;
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Registro de asistencia del grupo %s (%s)', v_nombre_grupo, p_fecha),
        academico_test.fn_grupo_establecimiento(p_fk_tgrupo),
        academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(p_fk_tgrupo)));

    RETURN academico_test.fn_asistencia_registrar_bulk_interno(
        p_fk_tgrupo, p_fk_tasignatura, p_fecha, p_bloque,
        p_registros, p_marcar_todos_valor, p_fk_tactividad,
        p_pk_usuario_solicitante);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_registrar_bulk(
    BIGINT, BIGINT, BIGINT, DATE, NUMERIC, JSONB, NUMERIC, BIGINT
) IS 'POST /asistencias/registrar. WRAPPER: 1) fn_asistencia_gate_escritura, 2) fn_asistencia_validar_fecha_no_futura / _contexto / _periodo_abierto / _docente_asignado (V136; Regla 74), 3) delega en fn_asistencia_registrar_bulk_interno (V137), previa etiqueta de auditoria (fn_audit_declarar). Contrato de parametros y de retorno sin cambios respecto a V464.';

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
    v_nombre_grupo   VARCHAR(130);
BEGIN
    SELECT m.FK_TGRUPO, a.FK_TASIGNATURA, a.FK_TACTIVIDAD
      INTO v_fk_tgrupo, v_fk_tasignatura, v_fk_tactividad
      FROM academico_test.TASISTENCIA a
      JOIN academico_test.TMATRICULA m ON m.PK_TMATRICULA = a.FK_TMATRICULA
     WHERE a.PK_TASISTENCIA = p_pk_tasistencia AND a.ACTIVE = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'registro de asistencia (%) no existe o no esta activo', p_pk_tasistencia
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM academico_test.fn_asistencia_gate_escritura(
        p_pk_usuario_solicitante, v_fk_tgrupo, 'EDITAR');

    PERFORM academico_test.fn_asistencia_validar_periodo_abierto(v_fk_tgrupo, 'editar');
    PERFORM academico_test.fn_asistencia_validar_docente_asignado(
        p_pk_usuario_solicitante, v_fk_tgrupo, v_fk_tasignatura, v_fk_tactividad);

    SELECT NOMBRE INTO v_nombre_grupo FROM academico_test.TGRUPO WHERE PK_TGRUPO = v_fk_tgrupo;
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Edicion de asistencia (registro %s) del grupo %s', p_pk_tasistencia, v_nombre_grupo),
        academico_test.fn_grupo_establecimiento(v_fk_tgrupo),
        academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(v_fk_tgrupo)));

    RETURN academico_test.fn_asistencia_editar_interno(
        p_pk_tasistencia, v_fk_tgrupo, p_tipo_asistencia_valor, p_observacion,
        p_fk_soporte_archivo, p_limpiar_archivo, p_limpiar_observacion,
        p_pk_usuario_solicitante);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_asistencia_editar(
    BIGINT, BIGINT, NUMERIC, VARCHAR, BIGINT, BOOLEAN, BOOLEAN
) IS 'PATCH /asistencias/:ID. WRAPPER: resuelve grupo/asignatura/actividad del registro, 1) fn_asistencia_gate_escritura, 2) fn_asistencia_validar_periodo_abierto / _docente_asignado (V136; Regla 74), 3) delega en fn_asistencia_editar_interno (V137), previa etiqueta de auditoria (fn_audit_declarar). fn_asistencia_editar_bulk (V438) hereda la Regla 74 y la etiqueta al llamar a esta por cada pk. Contrato sin cambios respecto a V220.';
