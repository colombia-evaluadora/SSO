-- V496.7 - Calificación de actividades: wrappers de los endpoints. Mismas
-- firmas de siempre; cada uno comprueba existencia, estado, alcance y la
-- propiedad de los resultados (Regla 54), declara la etiqueta de auditoría y
-- delega en su _interno. La definición del instrumento vive en V496.3.
-- Depende de: V496.5 (validaciones y assert de propiedad), V496.6 (_interno),
-- V496.3 (fn_actividad_auditar), V277 (alcance).

SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_actividad_nota_calificar_escala_bulk(BIGINT, BIGINT, BIGINT, NUMERIC, BIGINT[], DATE);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_assert_resultados(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_accion                 VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_validar_existente(p_pk_tactividad);
    PERFORM academico_test.fn_actividad_validar_activa(p_pk_tactividad);
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, p_accion, NULL, NULL, NULL, p_pk_tactividad);
    PERFORM academico_test.fn_actividad_assert_propietario_resultados(p_pk_usuario_solicitante, p_pk_tactividad);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT,
    p_calificacion             JSONB,
    p_fecha                    DATE DEFAULT CURRENT_DATE
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_pk BIGINT := academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante);
BEGIN
    PERFORM academico_test.fn_actividad_assert_resultados(p_pk_usuario_solicitante, v_pk, 'EDITAR');
    PERFORM academico_test.fn_actividad_auditar(p_pk_usuario_solicitante, v_pk,
        format('Calificación de %s en %s',
               COALESCE(academico_test.fn_actividad_estudiante_nombre(
                   (SELECT FK_TMATRICULA FROM academico_test.TACTIVIDAD_ESTUDIANTE
                     WHERE PK_TACTIVIDAD_ESTUDIANTE = p_pk_tactividad_estudiante)), 'un estudiante'),
               academico_test.fn_actividad_etiqueta(v_pk)));
    RETURN academico_test.fn_actividad_nota_calificar_interno(
        p_pk_usuario_solicitante, p_pk_tactividad_estudiante, p_calificacion, p_fecha);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_rubrica_bulk(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_pk_criterio              BIGINT,
    p_pk_nivel                 BIGINT,
    p_pk_tactividad_estudiante BIGINT[],
    p_fecha                    DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (pk_tactividad_estudiante BIGINT, criterios_totales INT, criterios_cubiertos INT,
               calificacion NUMERIC, calificacion_actualizada BOOLEAN)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_assert_resultados(p_pk_usuario_solicitante, p_pk_tactividad, 'EDITAR');
    PERFORM academico_test.fn_actividad_auditar(p_pk_usuario_solicitante, p_pk_tactividad,
        format('Calificación en bloque con rúbrica de %s estudiante(s) en %s',
               COALESCE(array_length(p_pk_tactividad_estudiante, 1), 0), academico_test.fn_actividad_etiqueta(p_pk_tactividad)));
    RETURN QUERY SELECT * FROM academico_test.fn_actividad_nota_calificar_rubrica_bulk_interno(
        p_pk_usuario_solicitante, p_pk_tactividad, p_pk_criterio, p_pk_nivel, p_pk_tactividad_estudiante, p_fecha);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_cotejo_bulk(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_pk_item                  BIGINT,
    p_cumplido                 CHAR(1),
    p_pk_tactividad_estudiante BIGINT[],
    p_fecha                    DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (pk_tactividad_estudiante BIGINT, items_totales INT, items_cumplidos INT, calificacion NUMERIC)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_assert_resultados(p_pk_usuario_solicitante, p_pk_tactividad, 'EDITAR');
    PERFORM academico_test.fn_actividad_auditar(p_pk_usuario_solicitante, p_pk_tactividad,
        format('Calificación en bloque con lista de cotejo de %s estudiante(s) en %s',
               COALESCE(array_length(p_pk_tactividad_estudiante, 1), 0), academico_test.fn_actividad_etiqueta(p_pk_tactividad)));
    RETURN QUERY SELECT * FROM academico_test.fn_actividad_nota_calificar_cotejo_bulk_interno(
        p_pk_usuario_solicitante, p_pk_tactividad, p_pk_item, p_cumplido, p_pk_tactividad_estudiante, p_fecha);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_calificar_escala_bulk(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad            BIGINT,
    p_pk_nivel                 BIGINT,
    p_valor_numerico           NUMERIC,
    p_criterios                JSONB,
    p_pk_tactividad_estudiante BIGINT[],
    p_fecha                    DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (pk_tactividad_estudiante BIGINT, calificacion NUMERIC)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_assert_resultados(p_pk_usuario_solicitante, p_pk_tactividad, 'EDITAR');
    PERFORM academico_test.fn_actividad_auditar(p_pk_usuario_solicitante, p_pk_tactividad,
        format('Calificación en bloque con escala de valoración de %s estudiante(s) en %s',
               COALESCE(array_length(p_pk_tactividad_estudiante, 1), 0), academico_test.fn_actividad_etiqueta(p_pk_tactividad)));
    RETURN QUERY SELECT * FROM academico_test.fn_actividad_nota_calificar_escala_bulk_interno(
        p_pk_usuario_solicitante, p_pk_tactividad, p_pk_nivel, p_valor_numerico, p_criterios,
        p_pk_tactividad_estudiante, p_fecha);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_nota_obtener(
    p_pk_usuario_solicitante   BIGINT,
    p_pk_tactividad_estudiante BIGINT
)
RETURNS TABLE (instrumento VARCHAR, calificacion NUMERIC, calificable CHAR, observacion VARCHAR, detalle JSONB,
               evidencias JSONB, nota_homologada NUMERIC, valoracion VARCHAR, formato_valor VARCHAR,
               resultado_instrumento JSONB)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_assert_resultados(p_pk_usuario_solicitante,
        academico_test.fn_actividad_estudiante_actividad(p_pk_tactividad_estudiante), 'VER');
    RETURN QUERY SELECT * FROM academico_test.fn_actividad_nota_obtener_interno(p_pk_tactividad_estudiante);
END;
$$;

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_estudiantes_calificaciones_listar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT,
    p_fecha                  DATE DEFAULT CURRENT_DATE,
    p_search                 VARCHAR DEFAULT NULL
)
RETURNS TABLE (pk_tactividad_estudiante BIGINT, pk_tmatricula BIGINT, nombre_estudiante VARCHAR, instrumento VARCHAR,
               fecha DATE, pk_tasistencia BIGINT, fk_tlv_tipo_asistencia BIGINT, tipo_asistencia VARCHAR,
               asistencia_observacion VARCHAR, fk_soporte_archivo BIGINT, calificacion NUMERIC, calificable CHAR,
               nota_observacion VARCHAR, es_formativa BOOLEAN, fecha_asistencia DATE, nota_homologada NUMERIC,
               valoracion VARCHAR, formato_valor VARCHAR, resultado_instrumento JSONB)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    PERFORM academico_test.fn_actividad_assert_resultados(p_pk_usuario_solicitante, p_pk_tactividad, 'VER');
    RETURN QUERY SELECT * FROM academico_test.fn_actividad_estudiantes_calificaciones_listar_interno(
        p_pk_tactividad, COALESCE(p_fecha, CURRENT_DATE), p_search);
END;
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_assert_resultados(BIGINT, BIGINT, VARCHAR)
    IS 'Gate común de los endpoints de resultados: existencia (P0002), actividad no eliminada (22023), alcance p_accion sobre PLANEADOR (42501) y propiedad de los resultados (Regla 54, 42501).';
COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar(BIGINT, BIGINT, JSONB, DATE)
    IS 'PUT /planeador/actividades/estudiantes/:ID/calificar. Wrapper: gate EDITAR, Regla 54 y etiqueta "Calificación de <estudiante> en <actividad>"; delega en fn_actividad_nota_calificar_interno.';
COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_rubrica_bulk(BIGINT, BIGINT, BIGINT, BIGINT, BIGINT[], DATE)
    IS 'PUT /planeador/actividades/:ID/calificar-bulk/rubrica. Wrapper: gate EDITAR, Regla 54 y etiqueta; delega en fn_actividad_nota_calificar_rubrica_bulk_interno.';
COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_cotejo_bulk(BIGINT, BIGINT, BIGINT, CHAR, BIGINT[], DATE)
    IS 'PUT /planeador/actividades/:ID/calificar-bulk/cotejo. Wrapper: gate EDITAR, Regla 54 y etiqueta; delega en fn_actividad_nota_calificar_cotejo_bulk_interno.';
COMMENT ON FUNCTION academico_test.fn_actividad_nota_calificar_escala_bulk(BIGINT, BIGINT, BIGINT, NUMERIC, JSONB, BIGINT[], DATE)
    IS 'PUT /planeador/actividades/:ID/calificar-bulk/escala. Wrapper: gate EDITAR, Regla 54 y etiqueta; delega en fn_actividad_nota_calificar_escala_bulk_interno.';
COMMENT ON FUNCTION academico_test.fn_actividad_nota_obtener(BIGINT, BIGINT)
    IS 'GET /planeador/actividades/estudiantes/:ID/nota. Wrapper: gate VER y Regla 54; delega en fn_actividad_nota_obtener_interno.';
COMMENT ON FUNCTION academico_test.fn_actividad_estudiantes_calificaciones_listar(BIGINT, BIGINT, DATE, VARCHAR)
    IS 'GET /planeador/actividades/:ID/calificaciones. Wrapper: gate VER y Regla 54; delega en fn_actividad_estudiantes_calificaciones_listar_interno.';
