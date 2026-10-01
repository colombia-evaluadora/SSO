-- ===========================================================================
-- V529 — GET /planeador/actividades/calendario: agrega
-- ?grado_asignatura_pares= (V528), mismo contrato CSV que V527 le dio a
-- GET /planeador/actividades/mias (string_to_array de "grado:asignatura",
-- nunca JSONB -- QUERY.* de un GET siempre llega como String al binder).
-- Dollar-quoting para reescribir el texto completo del query, igual que
-- V527, sin depender de que forma tenga el texto vigente.
-- Depende de: V251 (contrato base del endpoint), V528.
-- ===========================================================================

SET search_path TO academico_test, public;

UPDATE public.query q
   SET query = $q$SELECT * FROM academico_test.fn_actividad_calendario_docente(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.FECHA_DESDE AS DATE),
    CAST(:QUERY.FECHA_HASTA AS DATE),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.UNIDAD AS BIGINT),
    COALESCE(CAST(:QUERY.DIAS_GRACIA AS INT), 2),
    string_to_array(NULLIF(TRIM(CAST(:QUERY.GRADO_ASIGNATURA_PARES AS VARCHAR)), ''), ',')
);$q$,
       param_types = (COALESCE(q.param_types, '{}'::jsonb) - 'QUERY.GRADO_ASIGNATURA_PARES')
                     || '{
                          "QUERY.FECHA_DESDE": "DATE", "QUERY.FECHA_HASTA": "DATE",
                          "QUERY.ASIGNATURA": "BIGINT", "QUERY.GRUPO": "BIGINT",
                          "QUERY.UNIDAD": "BIGINT", "QUERY.DIAS_GRACIA": "INT",
                          "QUERY.GRADO_ASIGNATURA_PARES": "VARCHAR"
                        }'::jsonb
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid       = 'eval-col'
   AND q.path_template   = '/planeador/actividades/calendario'
   AND q.http_method     = 'GET'
   AND q.query LIKE '%fn_actividad_calendario_docente%';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.query
         WHERE path_template = '/planeador/actividades/calendario' AND http_method = 'GET'
           AND query LIKE '%GRADO_ASIGNATURA_PARES AS VARCHAR%'
    ) THEN
        RAISE EXCEPTION 'No se actualizo GET /planeador/actividades/calendario (falta la fila o el microservicio eval-col)';
    END IF;
END $$;
