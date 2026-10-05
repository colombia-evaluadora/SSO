-- V496.20 - Aprobación del Coordinador, capa 3 de 4: wrappers con gate.
-- Aprueba o rechaza el Coordinador académico de la sede del grupo (o el super
-- administrador, nivel 0); el listado de pendientes es su aviso (Regla 70).
-- La edición de asistencia (fn_asistencia_editar, V138) abre la solicitud de
-- la Regla 75 con fn_asistencia_correccion_solicitar_interno. La marca de
-- informe desactualizado (Regla 71) se lee con el gate de Informes. El lote
-- (aprobar/rechazar masivo) resuelve cada solicitud con su wrapper.
-- Depende de: V496.19, V277, V489, V136.

SET search_path TO academico_test, public;

CREATE OR REPLACE FUNCTION academico_test.fn_usuario_es_coordinador_sede(
    p_pk_tusuario BIGINT,
    p_fk_tsede    BIGINT
)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM academico_test.fn_usuario_sedes_coordinador(p_pk_tusuario) s
         WHERE p_fk_tsede IS NULL OR s = p_fk_tsede);
$$;

COMMENT ON FUNCTION academico_test.fn_usuario_es_coordinador_sede(BIGINT, BIGINT)
    IS 'TRUE si el usuario es Coordinador (fn_usuario_sedes_coordinador) en la sede; con sede NULL, en alguna. La usan los gates de aprobación.';

-- El capability VER del planeador más el alcance del grupo deciden "sobre qué";
-- el rol decide "quién": aprobar es del Coordinador, no de todo el que edita.
CREATE OR REPLACE FUNCTION academico_test.fn_solicitud_aprobacion_assert_aprobador(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tsolicitud          BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_fk_tgrupo BIGINT;
    v_grupo     VARCHAR;
BEGIN
    SELECT s.FK_TGRUPO, g.NOMBRE INTO v_fk_tgrupo, v_grupo
      FROM academico_test.TSOLICITUD_APROBACION s
      JOIN academico_test.TGRUPO g ON g.PK_TGRUPO = s.FK_TGRUPO
     WHERE s.PK_TSOLICITUD_APROBACION = p_pk_tsolicitud;

    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', p_fk_tgrupo => v_fk_tgrupo);

    BEGIN
        PERFORM academico_test.fn_solicitud_aprobacion_assert_coordinador(
            p_pk_usuario_solicitante,
            academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(v_fk_tgrupo)));
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE EXCEPTION 'Solo el Coordinador académico de la sede del grupo % puede resolver esta solicitud', v_grupo
            USING ERRCODE = '42501';
    END;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_solicitud_aprobacion_assert_aprobador(BIGINT, BIGINT)
    IS 'Gate del aprobador: alcance del planeador sobre el grupo de la solicitud (fn_planeador_assert_alcance) y Coordinador en la sede del grupo (nivel 0 bypass delegado en fn_solicitud_aprobacion_assert_coordinador, re-lanzado con el nombre del grupo). 42501 si no.';

CREATE OR REPLACE FUNCTION academico_test.fn_solicitud_aprobacion_puede_aprobar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tsolicitud          BIGINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_solicitud_aprobacion_assert_aprobador(p_pk_usuario_solicitante, p_pk_tsolicitud);
    RETURN TRUE;
EXCEPTION WHEN insufficient_privilege THEN
    RETURN FALSE;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_solicitud_aprobacion_puede_aprobar(BIGINT, BIGINT)
    IS 'Variante booleana de fn_solicitud_aprobacion_assert_aprobador para filtrar listados: envuelve el assert y captura el 42501, así no pueden divergir.';

DROP FUNCTION IF EXISTS academico_test.fn_solicitud_aprobacion_assert_coordinador(BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_solicitud_aprobacion_assert_coordinador(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tsede               BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    -- p_fk_tsede NULL (listado) = Coordinador en alguna sede; con sede, en ESA.
    IF academico_test.fn_usuario_categoria_rol_nivel(p_pk_usuario_solicitante) IS DISTINCT FROM 0
       AND NOT academico_test.fn_usuario_es_coordinador_sede(p_pk_usuario_solicitante, p_fk_tsede) THEN
        RAISE EXCEPTION 'Las solicitudes de aprobación solo las consulta el Coordinador académico'
            USING ERRCODE = '42501';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_solicitud_aprobacion_assert_coordinador(BIGINT, BIGINT)
    IS 'Gate base del Coordinador: nivel 0 o Coordinador de p_fk_tsede (NULL = en alguna). La usan fn_solicitud_aprobacion_listar (sede NULL, el alcance por fila lo filtra fn_solicitud_aprobacion_puede_aprobar) y fn_solicitud_aprobacion_assert_aprobador (sede del grupo, con su propio mensaje). 42501 si no.';

DROP FUNCTION IF EXISTS academico_test.fn_solicitud_aprobacion_listar(BIGINT, VARCHAR, BIGINT, VARCHAR);

CREATE OR REPLACE FUNCTION academico_test.fn_solicitud_aprobacion_listar(
    p_pk_usuario_solicitante BIGINT,
    p_tipo                   VARCHAR DEFAULT NULL,
    p_fk_tgrupo              BIGINT  DEFAULT NULL,
    p_estado                 VARCHAR DEFAULT 'PENDIENTE'
)
RETURNS TABLE (
    pk_tsolicitud_aprobacion BIGINT,
    tipo                     VARCHAR,
    tipo_nombre              VARCHAR,
    estado                   VARCHAR,
    tabla_objeto             VARCHAR,
    fk_objeto                BIGINT,
    fk_tgrupo                BIGINT,
    grupo                    VARCHAR,
    fk_tasignatura           BIGINT,
    asignatura               VARCHAR,
    fk_tperiodo_evaluacion   BIGINT,
    periodo_evaluacion       VARCHAR,
    fk_tactividad            BIGINT,
    actividad                VARCHAR,
    estudiante               VARCHAR,
    valor_anterior           JSONB,
    valor_propuesto          JSONB,
    solicitante              VARCHAR,
    fecha_solicitud          TIMESTAMP,
    motivo                   VARCHAR,
    aprobador                VARCHAR,
    fecha_resolucion         TIMESTAMP,
    motivo_resolucion        VARCHAR,
    fk_tmatricula            BIGINT,
    fecha                    DATE,
    bloque                   NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
#variable_conflict use_column
BEGIN
    PERFORM academico_test.fn_solicitud_aprobacion_assert_coordinador(p_pk_usuario_solicitante);
    RETURN QUERY
    SELECT i.*
      FROM academico_test.fn_solicitud_aprobacion_listar_interno(p_estado, p_tipo, p_fk_tgrupo) i
     WHERE academico_test.fn_solicitud_aprobacion_puede_aprobar(p_pk_usuario_solicitante, i.pk_tsolicitud_aprobacion)
     ORDER BY i.fecha_solicitud, i.pk_tsolicitud_aprobacion;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_solicitud_aprobacion_listar(BIGINT, VARCHAR, BIGINT, VARCHAR)
    IS 'GET /aprobaciones/pendientes: solicitudes que el usuario puede resolver (Coordinador de la sede del grupo o nivel 0), por tipo, grupo y estado (PENDIENTE por defecto). Es el aviso de la Regla 70. 42501 si no es Coordinador en ninguna sede.';

CREATE OR REPLACE FUNCTION academico_test.fn_solicitud_aprobacion_aprobar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tsolicitud          BIGINT,
    p_motivo                 VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_fk_tgrupo BIGINT;
BEGIN
    PERFORM academico_test.fn_solicitud_aprobacion_validar_existe(p_pk_tsolicitud);
    PERFORM academico_test.fn_solicitud_aprobacion_validar_pendiente(p_pk_tsolicitud);
    PERFORM academico_test.fn_solicitud_aprobacion_assert_aprobador(p_pk_usuario_solicitante, p_pk_tsolicitud);
    PERFORM academico_test.fn_solicitud_aprobacion_validar_motivo(p_motivo, FALSE);

    SELECT FK_TGRUPO INTO v_fk_tgrupo FROM academico_test.TSOLICITUD_APROBACION
     WHERE PK_TSOLICITUD_APROBACION = p_pk_tsolicitud;
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Aprobación de la solicitud %s (%s)', p_pk_tsolicitud,
               academico_test.fn_solicitud_aprobacion_tipo(p_pk_tsolicitud)),
        academico_test.fn_grupo_establecimiento(v_fk_tgrupo),
        academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(v_fk_tgrupo)));

    RETURN academico_test.fn_solicitud_aprobacion_aprobar_interno(p_pk_usuario_solicitante, p_pk_tsolicitud, p_motivo);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_solicitud_aprobacion_aprobar(BIGINT, BIGINT, VARCHAR)
    IS 'POST /aprobaciones/:ID/aprobar: el Coordinador aprueba la solicitud y el cambio se aplica (recuperación, corrección de resultado o de asistencia); marca el informe ya emitido como desactualizado (Regla 71). Orden: P0002 → 22023 (ya resuelta) → 42501 → 22023 (motivo > 1000).';

CREATE OR REPLACE FUNCTION academico_test.fn_solicitud_aprobacion_rechazar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tsolicitud          BIGINT,
    p_motivo                 VARCHAR
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_fk_tgrupo BIGINT;
BEGIN
    PERFORM academico_test.fn_solicitud_aprobacion_validar_existe(p_pk_tsolicitud);
    PERFORM academico_test.fn_solicitud_aprobacion_validar_pendiente(p_pk_tsolicitud);
    PERFORM academico_test.fn_solicitud_aprobacion_assert_aprobador(p_pk_usuario_solicitante, p_pk_tsolicitud);
    PERFORM academico_test.fn_solicitud_aprobacion_validar_motivo(p_motivo, TRUE);

    SELECT FK_TGRUPO INTO v_fk_tgrupo FROM academico_test.TSOLICITUD_APROBACION
     WHERE PK_TSOLICITUD_APROBACION = p_pk_tsolicitud;
    PERFORM academico_test.fn_audit_declarar(
        p_pk_usuario_solicitante,
        format('Rechazo de la solicitud %s (%s)', p_pk_tsolicitud,
               academico_test.fn_solicitud_aprobacion_tipo(p_pk_tsolicitud)),
        academico_test.fn_grupo_establecimiento(v_fk_tgrupo),
        academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(v_fk_tgrupo)));

    RETURN academico_test.fn_solicitud_aprobacion_rechazar_interno(p_pk_usuario_solicitante, p_pk_tsolicitud, p_motivo);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_solicitud_aprobacion_rechazar(BIGINT, BIGINT, VARCHAR)
    IS 'POST /aprobaciones/:ID/rechazar: el Coordinador rechaza la solicitud con motivo obligatorio; el valor vigente no cambia (Regla 70). Orden: P0002 → 22023 (ya resuelta) → 42501 → 22023 (motivo).';

CREATE OR REPLACE FUNCTION academico_test.fn_solicitud_aprobacion_validar_lote(p_ids BIGINT[])
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF COALESCE(cardinality(p_ids), 0) = 0 THEN
        RAISE EXCEPTION 'Indique al menos una solicitud' USING ERRCODE = '22023';
    END IF;
    IF cardinality(p_ids) > 500 THEN
        RAISE EXCEPTION 'Se pueden resolver hasta 500 solicitudes a la vez (llegaron %)', cardinality(p_ids)
            USING ERRCODE = '22023';
    END IF;
END;
$$;

COMMENT ON FUNCTION academico_test.fn_solicitud_aprobacion_validar_lote(BIGINT[])
    IS '22023 si el lote de solicitudes viene vacío o trae más de 500. La usa fn_solicitud_aprobacion_resolver_masivo.';

CREATE OR REPLACE FUNCTION academico_test.fn_solicitud_aprobacion_resolver_masivo(
    p_pk_usuario_solicitante BIGINT,
    p_aprobar                BOOLEAN,
    p_ids                    BIGINT[],
    p_motivo                 VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_id        BIGINT;
    v_resueltas BIGINT[] := '{}';
    v_fallidas  JSONB    := '[]'::jsonb;
BEGIN
    PERFORM academico_test.fn_solicitud_aprobacion_validar_lote(p_ids);
    -- El motivo es del lote: si falta al rechazar, no se intenta ninguna.
    PERFORM academico_test.fn_solicitud_aprobacion_validar_motivo(p_motivo, NOT p_aprobar);

    FOR v_id IN SELECT x FROM unnest(p_ids) WITH ORDINALITY AS t(x, n)
                 WHERE x IS NOT NULL GROUP BY x ORDER BY min(n) LOOP
        BEGIN
            IF p_aprobar THEN
                PERFORM academico_test.fn_solicitud_aprobacion_aprobar(p_pk_usuario_solicitante, v_id, p_motivo);
            ELSE
                PERFORM academico_test.fn_solicitud_aprobacion_rechazar(p_pk_usuario_solicitante, v_id, p_motivo);
            END IF;
            v_resueltas := v_resueltas || v_id;
        EXCEPTION WHEN OTHERS THEN
            v_fallidas := v_fallidas || jsonb_build_object('id', v_id, 'codigo', SQLSTATE, 'error', SQLERRM);
        END;
    END LOOP;

    RETURN jsonb_build_object('resueltas', to_jsonb(v_resueltas), 'fallidas', v_fallidas);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_solicitud_aprobacion_resolver_masivo(BIGINT, BOOLEAN, BIGINT[], VARCHAR)
    IS 'POST /aprobaciones/aprobar-masivo y /aprobaciones/rechazar-masivo: resuelve cada PK de p_ids con fn_solicitud_aprobacion_aprobar o _rechazar (su gate y validaciones), en orden y sin repetidos; la que falla se deshace sola y queda en fallidas. Devuelve {resueltas: [pk], fallidas: [{id, codigo, error}]}. 22023 si el lote está vacío, pasa de 500 o falta el motivo al rechazar.';

-- ---------------------------------------------------------------------------
-- Regla 71: lectura de la marca con el gate de Informes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_informe_desactualizado(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tperiodo_evaluacion BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM academico_test.TGRUPO WHERE PK_TGRUPO = p_fk_tgrupo AND ACTIVE = TRUE) THEN
        RAISE EXCEPTION 'No se encontro el grupo solicitado' USING ERRCODE = 'P0002';
    END IF;
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'INFORMES', 'VER',
        academico_test.fn_grupo_establecimiento(p_fk_tgrupo),
        academico_test.fn_periodo_sede(academico_test.fn_grupo_periodo(p_fk_tgrupo)),
        academico_test.fn_grupo_jornada(p_fk_tgrupo));
    PERFORM academico_test.fn_informe_assert_grupo_propio(p_pk_usuario_solicitante, p_fk_tgrupo);

    RETURN academico_test.fn_informe_desactualizado_interno(p_fk_tgrupo, p_fk_tperiodo_evaluacion);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_informe_desactualizado(BIGINT, BIGINT, BIGINT)
    IS 'GET /informes/desactualizado: si el informe del grupo y periodo de evaluación se emitió antes de una aprobación que cambió valores (Regla 71), con el mensaje estático y los cambios. Se limpia al reemitir el informe. Gate VER de INFORMES con alcance del grupo y recorte por grupo propio (V489).';
