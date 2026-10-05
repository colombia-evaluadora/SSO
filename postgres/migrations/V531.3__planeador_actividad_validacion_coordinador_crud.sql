-- V531.3 - Validación de la ACTIVIDAD por el Coordinador, capa 3 de 4: wrappers
-- con gate. Valida quien resuelve solicitudes de aprobación en la SEDE de la
-- actividad (fn_solicitud_aprobacion_assert_rol_aprobador: Coordinador de esa
-- sede; Rector, Jefe de sistema o Auxiliar administrativo de su EE; nivel 0),
-- con VER del planeador sobre la actividad, y nunca quien la planeó.
-- Depende de: V531.2, V496.20 (rol aprobador), V277 (alcance), V479 (sede),
-- V496.1 (existencia, etiqueta), V496.3 (fn_actividad_auditar).

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validacion_assert_validador(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_sede       BIGINT;
    v_sede_nom   VARCHAR;
    v_created_by VARCHAR;
BEGIN
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', p_pk_tactividad => p_pk_tactividad);

    SELECT academico_test.fn_actividad_sede(a.FK_TGRUPO, a.FK_TUNIDAD), a.CREATED_BY
      INTO v_sede, v_created_by
      FROM academico_test.TACTIVIDAD a
     WHERE a.PK_TACTIVIDAD = p_pk_tactividad;

    IF v_sede IS NULL
       AND academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION '% no tiene grupo ni unidad, así que no se puede saber a qué sede pertenece para validarla',
            academico_test.fn_actividad_etiqueta(p_pk_tactividad)
            USING ERRCODE = '42501';
    END IF;

    IF v_sede IS NOT NULL THEN
        BEGIN
            PERFORM academico_test.fn_solicitud_aprobacion_assert_rol_aprobador(p_pk_usuario_solicitante, v_sede);
        EXCEPTION WHEN insufficient_privilege THEN
            SELECT NOMBRE INTO v_sede_nom FROM academico_test.TSEDE WHERE PK_TSEDE = v_sede;
            RAISE EXCEPTION 'Solo el Coordinador académico de la sede %, o el Rector, el Jefe de sistema o el Auxiliar administrativo de su establecimiento, puede validar esta actividad', v_sede_nom
                USING ERRCODE = '42501';
        END;
    END IF;

    IF v_created_by = p_pk_usuario_solicitante::VARCHAR THEN
        RAISE EXCEPTION 'No puede validar una actividad que usted mismo planeó'
            USING ERRCODE = '42501';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_validacion_assert_validador(BIGINT, BIGINT)
    IS 'Gate del validador de la actividad: VER del planeador sobre ella (fn_planeador_assert_alcance), rol aprobador en la sede de la actividad (fn_solicitud_aprobacion_assert_rol_aprobador; actividad sin sede solo nivel 0) y no ser quien la creó. 42501 con mensaje legible si no.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validacion_puede_validar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_validacion_assert_validador(p_pk_usuario_solicitante, p_pk_tactividad);
    RETURN TRUE;
EXCEPTION WHEN insufficient_privilege THEN
    RETURN FALSE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_validacion_puede_validar(BIGINT, BIGINT)
    IS 'Variante booleana de fn_actividad_validacion_assert_validador (captura el 42501), para que el front sepa si mostrar el botón Aprobar.';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validacion_coordinador_consultar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_validar_existente(p_pk_tactividad);
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', p_pk_tactividad => p_pk_tactividad);

    RETURN academico_test.fn_actividad_validacion_coordinador_estado_interno(p_pk_tactividad)
        || jsonb_build_object('puedeValidar',
               academico_test.fn_actividad_validacion_puede_validar(p_pk_usuario_solicitante, p_pk_tactividad));
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_validacion_coordinador_consultar(BIGINT, BIGINT)
    IS 'GET /planeador/actividades/:ID/validacion-coordinador: estado de validación (fn_actividad_validacion_coordinador_estado_interno) más puedeValidar del usuario. Orden: P0002 → 42501 (VER del planeador sobre la actividad).';

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_validacion_coordinador_resolver(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_decision               VARCHAR,
    p_observacion            VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_validar_existente(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_activa(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validacion_validar_requerida(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validacion_assert_validador(p_pk_usuario_solicitante, p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validacion_validar_decision(p_decision, p_observacion);

    PERFORM academico_test.fn_actividad_auditar(
        p_pk_usuario_solicitante, p_pk_tactividad,
        format('%s de la planeación: %s',
               CASE upper(TRIM(p_decision)) WHEN 'APROBADA' THEN 'Aprobación' ELSE 'Declinación' END,
               academico_test.fn_actividad_etiqueta(p_pk_tactividad)));

    RETURN academico_test.fn_actividad_validacion_coordinador_resolver_interno(
        p_pk_usuario_solicitante, p_pk_tactividad, p_decision, p_observacion);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_validacion_coordinador_resolver(BIGINT, BIGINT, VARCHAR, VARCHAR)
    IS 'POST /planeador/actividades/:ID/validacion-coordinador: el Coordinador de la sede (fn_actividad_validacion_assert_validador) aprueba o declina la planeación; declinar exige observación. Reemplaza la decisión vigente. Orden: P0002 → 22023 (eliminada / no requiere validación) → 42501 → 22023 (decisión u observación).';
