-- ===========================================================================
-- V440 - Planeador: helper compartido de `campos_disponibles` para el criterio.
--
-- fn_actividad_criterio_campos_disponibles arma el bloque de criterio del
-- formulario de actividad a partir de VALORES ya resueltos, para que las
-- funciones de configuracion lo compongan en vez de repetirlo.
-- Depende de: V214.2, V282, V422, V223, V277, V73.
-- ===========================================================================

SET search_path TO academico_test, public;

DROP FUNCTION IF EXISTS academico_test.fn_actividad_criterio_campos_disponibles(BOOLEAN, BOOLEAN);

CREATE FUNCTION academico_test.fn_actividad_criterio_campos_disponibles(
    p_es_preescolar BOOLEAN,
    p_tiene_unidad  BOOLEAN
) RETURNS JSONB
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'visible',   NOT COALESCE(p_es_preescolar, FALSE) AND COALESCE(p_tiene_unidad, FALSE),
        'requerido', FALSE,
        'motivo', CASE
            WHEN COALESCE(p_es_preescolar, FALSE) AND COALESCE(p_tiene_unidad, FALSE)
                THEN 'El grado de la unidad pertenece al nivel Preescolar: la relacion con criterios de rubrica no aplica'
            WHEN COALESCE(p_es_preescolar, FALSE)
                THEN 'El grado pertenece al nivel Preescolar: la relacion con criterios de rubrica no aplica'
            WHEN NOT COALESCE(p_tiene_unidad, FALSE)
                THEN 'Los criterios pertenecen a la rubrica de una unidad; la actividad aun no tiene unidad'
            ELSE 'Opcional: la actividad puede relacionarse con criterios de la rubrica de la unidad'
        END);
$$;

COMMENT ON FUNCTION academico_test.fn_actividad_criterio_campos_disponibles(BOOLEAN, BOOLEAN) IS
    'Bloque criterio del formulario de actividad.';
