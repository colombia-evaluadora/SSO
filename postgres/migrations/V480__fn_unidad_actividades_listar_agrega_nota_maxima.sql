-- V480 — GET /planeador/unidades/:ID/actividades: wrapper de fn_unidad_actividades_listar.
--
-- Qué hace: existencia (P0002) → alcance VER → fn_unidad_actividades_listar_interno
-- (V492.2), que devuelve peso (PONDERACION) y puntaje (NOTA_MAXIMA, lo que el
-- docente captura en Sumatoria). A un docente de aula solo le lista las
-- actividades que creó (Regla 25c). DROP previo por el cambio de RETURNS TABLE.
-- Depende de: V216, V223 (modo Sumatoria), V277 (alcance), V492.2 (núcleo).

SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_unidad_actividades_listar(BIGINT, BIGINT, VARCHAR, BIGINT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT);

CREATE OR REPLACE FUNCTION academico_test.fn_unidad_actividades_listar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tunidad               BIGINT,
    p_search                   VARCHAR   DEFAULT NULL,
    p_fk_tgrupo                BIGINT    DEFAULT NULL,
    p_incluir_inactivas        BOOLEAN   DEFAULT FALSE,
    p_orden_por                VARCHAR   DEFAULT 'actividad',
    p_orden_asc                BOOLEAN   DEFAULT TRUE,
    p_limite                   INT       DEFAULT 50,
    p_offset                   INT       DEFAULT 0
)
RETURNS TABLE (
    pk_tactividad                   BIGINT,
    titulo                          VARCHAR,
    fk_tasignatura                  BIGINT,
    asignatura                      VARCHAR,
    fk_tlv_tipo_actividad           BIGINT,
    tipo_actividad                  VARCHAR,
    fk_tlv_instrumento_evaluacion   BIGINT,
    instrumento_evaluacion          VARCHAR,
    fk_tgrupo                       BIGINT,
    grupo                           VARCHAR,
    fk_tlv_jerarquia                BIGINT,
    jerarquia                       VARCHAR,
    ponderacion                     NUMERIC,
    nota_maxima                     NUMERIC,
    influencia                      NUMERIC,
    es_evaluativa                   VARCHAR,
    fecha_inicio                    DATE,
    fecha_cierre                    DATE,
    active                          BOOLEAN,
    total_count                     BIGINT
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_unidad_validar_existente(p_pk_tunidad);
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER', NULL, NULL, p_pk_tunidad);

    -- Un docente de aula no ve las actividades de sus colegas en la unidad compartida.
    RETURN QUERY SELECT * FROM academico_test.fn_unidad_actividades_listar_interno(
        p_pk_tunidad, p_search, p_fk_tgrupo, p_incluir_inactivas, p_orden_por, p_orden_asc,
        p_limite, p_offset,
        CASE WHEN academico_test.fn_usuario_es_docente_puro(p_pk_usuario_solicitante)
             THEN p_pk_usuario_solicitante END);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_unidad_actividades_listar(BIGINT, BIGINT, VARCHAR, BIGINT, BOOLEAN, VARCHAR, BOOLEAN, INT, INT)
    IS 'GET /planeador/unidades/:ID/actividades: existencia (P0002) → alcance VER; a un docente de aula solo le lista las actividades que creó (Regla 25c). Lógica en fn_unidad_actividades_listar_interno.';
