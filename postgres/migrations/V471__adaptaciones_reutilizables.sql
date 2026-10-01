-- V471 — Planeador: biblioteca de adaptaciones curriculares del docente.
--
-- Qué hace: GET /planeador/adaptaciones-reutilizables lista los archivos y
-- enlaces que el propio solicitante registró como versión modificada en otras
-- actividades (Regla 50), una fila por recurso; ?TIPO_ADAPTACION= filtra por
-- tipo. Wrapper con gate; el núcleo es
-- fn_actividad_adaptaciones_reutilizables_listar_interno (V496.2).
-- Depende de: V470 (TACTIVIDAD_ADAPTACION), V277 (alcance), V496.2.

DROP FUNCTION IF EXISTS academico_test.fn_actividad_adaptaciones_reutilizables_listar(
    BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, INTEGER, INTEGER, BIGINT);
DROP FUNCTION IF EXISTS academico_test.fn_actividad_adaptaciones_reutilizables_listar(
    BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, INTEGER, INTEGER, BIGINT, BIGINT);

CREATE OR REPLACE FUNCTION academico_test.fn_actividad_adaptaciones_reutilizables_listar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT  DEFAULT NULL,
    p_fk_tasignatura         BIGINT  DEFAULT NULL,
    p_fk_tfuncionario        BIGINT  DEFAULT NULL,
    p_search                 VARCHAR DEFAULT NULL,
    p_pagina                 INTEGER DEFAULT 1,
    p_tamano_pagina          INTEGER DEFAULT 20,
    p_fk_tgrupo              BIGINT  DEFAULT NULL,
    p_fk_tlv_tipo_adaptacion BIGINT  DEFAULT NULL
)
RETURNS TABLE(
    fk_tarchivo              BIGINT,
    nombre_archivo           VARCHAR,
    peso                     BIGINT,
    pk_tactividad_origen     BIGINT,
    titulo_actividad_origen  VARCHAR,
    fk_tlv_tipo_adaptacion   BIGINT,
    tipo_adaptacion          VARCHAR,
    descripcion              VARCHAR,
    url                      VARCHAR,
    nombre_plantilla         VARCHAR,
    pk_tactividad_adaptacion BIGINT,
    archivos                 JSONB,
    total_count              BIGINT
)
LANGUAGE plpgsql
STABLE
AS $function$
BEGIN
    IF p_pk_tactividad IS NULL AND p_fk_tgrupo IS NULL THEN
        RAISE EXCEPTION 'Indique la actividad o el grupo para consultar la biblioteca de adaptaciones'
            USING ERRCODE = '22023',
                  HINT    = 'Al editar se manda la actividad; al crear, el grupo que ya eligio el formulario';
    END IF;
    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER',
        CASE WHEN p_pk_tactividad IS NULL THEN p_fk_tgrupo END,
        NULL, NULL, p_pk_tactividad);

    RETURN QUERY
    SELECT * FROM academico_test.fn_actividad_adaptaciones_reutilizables_listar_interno(
        p_pk_usuario_solicitante::VARCHAR, p_pk_tactividad, p_fk_tasignatura, p_fk_tfuncionario,
        p_fk_tlv_tipo_adaptacion, p_search, p_pagina, p_tamano_pagina);
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_actividad_adaptaciones_reutilizables_listar(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, INTEGER, INTEGER, BIGINT, BIGINT)
    IS 'GET /planeador/adaptaciones-reutilizables: biblioteca de adaptaciones del propio docente (Regla 50): archivos y enlaces que el solicitante registró como versión modificada en otras actividades, una fila por recurso. Ancla ACTIVIDAD o GRUPO para el alcance VER (22023 sin ninguno); TIPO_ADAPTACION filtra por tipo. Delega en fn_actividad_adaptaciones_reutilizables_listar_interno.';

INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-adaptaciones-reutilizables-001',
    $q$SELECT * FROM academico_test.fn_actividad_adaptaciones_reutilizables_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.ACTIVIDAD AS BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.FUNCIONARIO AS BIGINT),
    CAST(:QUERY.SEARCH AS VARCHAR),
    COALESCE(CAST(:QUERY.PAGINA AS INT), 1),
    COALESCE(CAST(:QUERY.SIZE AS INT), 20),
    CAST(:QUERY.GRUPO AS BIGINT),
    CAST(:QUERY.TIPO_ADAPTACION AS BIGINT)
);$q$,
    'postgres', false, false,
    m.id_microservice,
    '/planeador/adaptaciones-reutilizables', 'SELECT', 'GET',
    '{"QUERY.ACTIVIDAD": "BIGINT", "QUERY.GRUPO": "BIGINT", "QUERY.ASIGNATURA": "BIGINT", "QUERY.FUNCIONARIO": "BIGINT", "QUERY.TIPO_ADAPTACION": "BIGINT", "QUERY.SEARCH": "VARCHAR", "QUERY.PAGINA": "INT", "QUERY.SIZE": "INT"}'::jsonb,
    NULL,
    'Biblioteca de adaptaciones del propio docente (Regla 50): los archivos y enlaces que el usuario registró como versión modificada del instrumento en otras actividades, una fila por recurso (al elegirlo se referencia, no se duplica). Hay que mandar ACTIVIDAD (al editar) o GRUPO (al crear) para el alcance; sin ninguno responde 400 (22023). TIPO_ADAPTACION filtra por el tipo ya elegido; ASIGNATURA y FUNCIONARIO siguen disponibles. Cada fila: fk_tarchivo, nombre_archivo, peso, url, nombre_plantilla, archivos [{fkTarchivo, nombre, peso}], pk_tactividad_adaptacion, actividad de origen, tipo y descripción. Pagina con PAGINA (1-based) y SIZE; SEARCH busca en nombre de plantilla, archivo, enlace y título de la actividad.',
    'adaptaciones-reutilizables', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO UPDATE
   SET query = EXCLUDED.query, param_types = EXCLUDED.param_types, detail = EXCLUDED.detail;

-- Roles: los mismos que ya pueden reemplazar la lista de adaptaciones.
INSERT INTO public.role_query (query_id, role_id)
SELECT nuevo.id_query, rq.role_id
  FROM public.query nuevo
  JOIN public.query hermano
    ON hermano.microservice_id = nuevo.microservice_id
   AND hermano.path_template   = '/planeador/actividades/:ID/adaptaciones'
   AND hermano.http_method     = 'PUT'
  JOIN public.role_query rq ON rq.query_id = hermano.id_query
 WHERE nuevo.uuid = 'eval-col-adaptaciones-reutilizables-001'
ON CONFLICT DO NOTHING;
