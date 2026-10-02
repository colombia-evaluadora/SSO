-- V469.4 — Planilla de calificación: funciones de endpoint (4 de 5).
--
-- Qué hace: wrappers delgados de GET /planeador/planilla/columnas,
-- /planeador/planilla/calificaciones y /planeador/periodos-evaluacion, con
-- las firmas que usan las filas de public.query (V469.5), en este orden:
-- filtro (22023/P0002/23503) -> alcance del Planeador sobre el grupo (42501)
-- -> periodo resuelto -> núcleo de V469.3. Lecturas: sin etiqueta.
-- Antes en V254, V454 y V469.
-- Depende de: V469.2, V469.3, V277 (fn_planeador_assert_alcance), V29, V37,
-- V224 (fn_funcionario_actual), V250 (fn_docente_periodo_vigente).

SET search_path TO academico_test, public;

-- Firmas anteriores (sin periodo / sin grupo): cambia la aridad.
DROP FUNCTION IF EXISTS academico_test.fn_planilla_columnas_listar(BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR);
DROP FUNCTION IF EXISTS academico_test.fn_planilla_calificaciones_listar(BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR, VARCHAR, INT, INT);
DROP FUNCTION IF EXISTS academico_test.fn_periodo_evaluacion_listar(BIGINT, BIGINT, BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_planilla_columnas_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tgrado              BIGINT  DEFAULT NULL,
    p_fecha_desde            DATE    DEFAULT NULL,
    p_fecha_hasta            DATE    DEFAULT NULL,
    p_search_actividad       VARCHAR DEFAULT NULL,
    p_fk_tperiodo_evaluacion BIGINT  DEFAULT NULL
)
RETURNS TABLE (
    orden_columna                  INTEGER,
    pk_tactividad                  BIGINT,
    titulo                         VARCHAR,
    fk_tunidad                     BIGINT,
    unidad                         VARCHAR,
    fk_tlv_instrumento_evaluacion  BIGINT,
    instrumento                    VARCHAR,
    instrumento_nombre             VARCHAR,
    metodo_valoracion              VARCHAR,
    ponderacion                    NUMERIC,
    nota_maxima                    NUMERIC,
    es_evaluativa                  VARCHAR,
    es_formativa                   BOOLEAN,
    fecha_inicio                   DATE,
    fecha_cierre                   DATE,
    estudiantes_asignados          BIGINT,
    estudiantes_calificados        BIGINT,
    pk_tperiodo_evaluacion         BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_planilla_grupo_asignatura_assert(
        p_fk_tgrupo, p_fk_tasignatura, p_fk_tgrado);
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', p_fk_tgrupo);

    RETURN QUERY
    SELECT * FROM academico_test.fn_planilla_columnas_listar_interno(
        p_fk_tgrupo, p_fk_tasignatura,
        academico_test.fn_planilla_periodo_eval_resolver(p_fk_tgrupo, p_fk_tperiodo_evaluacion),
        p_fecha_desde, p_fecha_hasta, p_search_actividad);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planilla_columnas_listar(BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR, BIGINT)
    IS 'GET /planeador/planilla/columnas: header de la "Planilla de calificacion" del (grupo, asignatura) en un periodo de evaluacion (?PERIODO= o el de fn_planilla_periodo_eval_resolver), en el mismo orden que las celdas de /planeador/planilla/calificaciones. 22023 si falta grupo o asignatura, P0002 si no existen, 23503 si el grado no es el del grupo o el periodo es de otro periodo academico; alcance VER del Planeador sobre el grupo. Delega en fn_planilla_columnas_listar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_planilla_calificaciones_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_tgrupo              BIGINT,
    p_fk_tasignatura         BIGINT,
    p_fk_tgrado              BIGINT  DEFAULT NULL,
    p_fecha_desde            DATE    DEFAULT NULL,
    p_fecha_hasta            DATE    DEFAULT NULL,
    p_search_actividad       VARCHAR DEFAULT NULL,
    p_search_estudiante      VARCHAR DEFAULT NULL,
    p_limite                 INT     DEFAULT 50,
    p_offset                 INT     DEFAULT 0,
    p_fk_tperiodo_evaluacion BIGINT  DEFAULT NULL
)
RETURNS TABLE (
    pk_tmatricula                    BIGINT,
    pk_testudiante                   BIGINT,
    nombre_estudiante                VARCHAR,
    definitiva_proyectada            NUMERIC,
    definitiva_registrada            NUMERIC,
    tendencia                        VARCHAR,
    celdas                           JSONB,
    total_count                      BIGINT,
    pk_tperiodo_evaluacion           BIGINT,
    definitiva_proyectada_homologada NUMERIC,
    definitiva_registrada_homologada NUMERIC,
    formato_valor                    VARCHAR,
    nota_maxima                      NUMERIC,
    es_numerico                      BOOLEAN
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_planilla_grupo_asignatura_assert(
        p_fk_tgrupo, p_fk_tasignatura, p_fk_tgrado);
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', p_fk_tgrupo);

    RETURN QUERY
    SELECT * FROM academico_test.fn_planilla_calificaciones_listar_interno(
        p_fk_tgrupo, p_fk_tasignatura,
        academico_test.fn_planilla_periodo_eval_resolver(p_fk_tgrupo, p_fk_tperiodo_evaluacion),
        p_fecha_desde, p_fecha_hasta, p_search_actividad, p_search_estudiante,
        p_limite, p_offset);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_planilla_calificaciones_listar(BIGINT, BIGINT, BIGINT, BIGINT, DATE, DATE, VARCHAR, VARCHAR, INT, INT, BIGINT)
    IS 'GET /planeador/planilla/calificaciones: una fila por matricula del grupo con la definitiva proyectada y registrada del periodo de evaluacion (?PERIODO= o el de fn_planilla_periodo_eval_resolver) y una celda por actividad de ese periodo, alineada con /planeador/planilla/columnas. Mismos errores que el header; alcance VER del Planeador sobre el grupo. Delega en fn_planilla_calificaciones_listar_interno.';

CREATE OR REPLACE FUNCTION academico_test.fn_periodo_evaluacion_listar(
    p_pk_usuario_solicitante BIGINT,
    p_fk_periodo             BIGINT DEFAULT NULL,
    p_fk_tlv_estado          BIGINT DEFAULT NULL,
    p_fk_tfuncionario        BIGINT DEFAULT NULL,
    p_fk_tgrupo              BIGINT DEFAULT NULL
)
RETURNS TABLE (
    pk_tperiodo_evaluacion  BIGINT,
    codigo                  VARCHAR,
    nombre                  VARCHAR,
    abreviacion             VARCHAR,
    fecha_inicio            DATE,
    fecha_fin               DATE,
    porcentaje              NUMERIC,
    vigente_hoy             BOOLEAN,
    fk_tlv_estado           BIGINT,
    estado_valor            VARCHAR,
    estado_nombre           VARCHAR,
    fk_tperiodo_academico   BIGINT,
    periodo_academico       VARCHAR
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_periodo BIGINT;
BEGIN
    PERFORM academico_test.fn_assert_permiso_seccion(
        p_pk_usuario_solicitante, 'PLANEADOR', 'VER');

    IF p_fk_tgrupo IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM academico_test.TGRUPO gr
                        WHERE gr.PK_TGRUPO = p_fk_tgrupo AND gr.ACTIVE = TRUE) THEN
            RAISE EXCEPTION 'No se encontro el grupo solicitado' USING ERRCODE = 'P0002';
        END IF;
        PERFORM academico_test.fn_planeador_assert_alcance(
            p_pk_usuario_solicitante, 'VER', p_fk_tgrupo);
        v_periodo := academico_test.fn_grupo_periodo(p_fk_tgrupo);
        IF p_fk_periodo IS NOT NULL AND p_fk_periodo <> v_periodo THEN
            RAISE EXCEPTION 'El grupo no pertenece al periodo academico solicitado'
                USING ERRCODE = '23503';
        END IF;
    ELSE
        -- Sin grupo: el pedido o el de las asignaciones del docente, con
        -- alcance territorial o auto-consulta (el territorial solo reconoce
        -- coordinador y globales); fuera de alcance, lista vacia.
        v_periodo := COALESCE(p_fk_periodo,
                              academico_test.fn_docente_periodo_vigente(
                                  COALESCE(p_fk_tfuncionario,
                                           academico_test.fn_funcionario_actual(p_pk_usuario_solicitante))));
        IF NOT ( academico_test.fn_periodo_usuario_puede_ver(p_pk_usuario_solicitante, v_periodo)
                 OR v_periodo = academico_test.fn_docente_periodo_vigente(
                                    academico_test.fn_funcionario_actual(p_pk_usuario_solicitante)) ) THEN
            RETURN;
        END IF;
    END IF;

    RETURN QUERY
    SELECT * FROM academico_test.fn_periodo_evaluacion_listar_interno(v_periodo, p_fk_tlv_estado);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_periodo_evaluacion_listar(BIGINT, BIGINT, BIGINT, BIGINT, BIGINT)
    IS 'GET /planeador/periodos-evaluacion: los periodos de evaluacion de un periodo academico. Con ?GRUPO= (el selector de la planilla) el periodo academico es el del grado del grupo y el gate es el alcance VER del Planeador sobre el grupo: sirve a docente, director y coordinador, y a un docente con carga en varias jornadas (P0002 si el grupo no existe, 23503 si ?PERIODO= no es el del grupo). Sin grupo, ?PERIODO= o el de las asignaciones del docente, con alcance territorial o auto-consulta. Gate VER sobre PLANEADOR. Delega en fn_periodo_evaluacion_listar_interno.';
