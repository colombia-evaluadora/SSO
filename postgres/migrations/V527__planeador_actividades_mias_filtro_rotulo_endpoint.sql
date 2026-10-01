-- ===========================================================================
-- V527 — GET /planeador/actividades/mias: agrega ?grado_asignatura_pares=
-- (V526). Reemplaza la version original de este archivo, que declaraba el
-- bind como JSONB: un parametro QUERY.* de un GET SIEMPRE llega como String
-- al binder, nunca como List/array, y JSONB ahi tiraba "La consulta esta
-- mal definida en el catalogo" en produccion -- mismo hallazgo que V253
-- para TEXT[]/VARCHAR[]. Ahora viaja como VARCHAR (CSV de "grado:asignatura",
-- string_to_array lo parte en SQL), mismo patron que V253/?estados=.
-- Reescribe el texto COMPLETO con dollar-quoting (sin escapar comillas
-- anidadas) en vez de un replace() textual: cubre tanto una base limpia
-- (V526 sin aplicar todavia) como un servidor que ya corrio la version
-- JSONB rota, sin depender de cual de los dos sea el estado actual.
-- Depende de: V279/V250 (contrato base del endpoint), V253 (patron CSV),
-- V526.
-- ===========================================================================

SET search_path TO academico_test, public;

UPDATE public.query q
   SET query = $q$SELECT * FROM academico_test.fn_actividad_listar_docente(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.SEARCH AS VARCHAR),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.UNIDAD AS BIGINT),
    string_to_array(NULLIF(TRIM(CAST(:QUERY.ESTADOS AS VARCHAR)), ''), ','),
    COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2),
    COALESCE(CAST(:QUERY.ORDEN_POR AS VARCHAR), 'fecha_inicio'),
    COALESCE(CAST(:QUERY.ORDEN_ASC AS BOOLEAN), TRUE),
    COALESCE(CAST(:QUERY.SIZE AS INT), 20),
    COALESCE(CAST(:QUERY.OFFSET AS INT), 0),
    CAST(:QUERY.DIA AS DATE),
    string_to_array(NULLIF(TRIM(CAST(:QUERY.GRADO_ASIGNATURA_PARES AS VARCHAR)), ''), ',')
);$q$,
       param_types = (COALESCE(q.param_types, '{}'::jsonb) - 'QUERY.GRADO_ASIGNATURA_PARES')
                     || '{
                          "QUERY.SEARCH": "VARCHAR", "QUERY.ASIGNATURA": "BIGINT",
                          "QUERY.GRUPO": "BIGINT", "QUERY.UNIDAD": "BIGINT",
                          "QUERY.ESTADOS": "VARCHAR", "QUERY.DIAS_GRACIA": "INT",
                          "QUERY.ORDEN_POR": "VARCHAR", "QUERY.ORDEN_ASC": "BOOLEAN",
                          "QUERY.SIZE": "INT", "QUERY.OFFSET": "INT", "QUERY.DIA": "DATE",
                          "QUERY.GRADO_ASIGNATURA_PARES": "VARCHAR"
                        }'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/mias'
   AND q.http_method     = 'GET'
   AND q.query LIKE '%fn_actividad_listar_docente%';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.query
         WHERE path_template = '/planeador/actividades/mias' AND http_method = 'GET'
           AND query LIKE '%GRADO_ASIGNATURA_PARES AS VARCHAR%'
    ) THEN
        RAISE EXCEPTION 'No se actualizo GET /planeador/actividades/mias (falta la fila o el microservicio eval-col)';
    END IF;
END $$;
