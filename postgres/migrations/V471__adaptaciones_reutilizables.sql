-- ===========================================================================
-- V471 - Biblioteca institucional de ADAPTACIONES curriculares.
--
--   fn_actividad_adaptaciones_reutilizables_listar
--   GET /planeador/adaptaciones-reutilizables
--
--
-- QUE RESUELVE
--   Mismo problema que V429 resolvio para materiales, pero para las
--   plantillas de adaptaciones curriculares (TACTIVIDAD_ADAPTACION.
--   FK_TARCHIVO, V470): el docente arma una adaptacion con "versión
--   modificada (archivo)" en una actividad y, al armar OTRA con el mismo
--   tipo de adaptacion, quiere reusar esa misma plantilla sin volver a
--   subirla. Hasta ahora "Seleccionar desde biblioteca institucional" era
--   un combo con dos opciones fijas ("Biblioteca - Plantilla A/B"), sin
--   backend detras.
--
--   Se espeja DIRECTO la forma final de V429 (ancla por actividad O grupo,
--   resultados acotados al establecimiento del ancla) en vez de repetir su
--   historia completa -- no existe una version anterior "solo con :ID" de
--   este endpoint que haya que arrastrar.
--
--
-- POR QUE UN ENDPOINT APARTE Y NO EL MISMO DE MATERIALES
--   Se decidio así explicitamente: son dos tablas (TACTIVIDAD_MATERIAL vs
--   TACTIVIDAD_ADAPTACION), dos formas del recurso (un tipoRecurso de
--   verdad vs un tipoAdaptacion) y dos consumidores front distintos
--   (galeria de materiales vs combobox de adaptaciones). Fusionarlos en un
--   solo listado heterogeneo hoy solo ahorra una migracion, a cambio de
--   acoplar dos dominios que hasta ahora eran independientes.
--
--
-- MISMAS DECISIONES QUE V429 (no se repiten, se heredan)
--   - Ancla: la actividad si la hay, el grupo si no. Sin ninguna, 22023.
--   - Gate: fn_planeador_assert_alcance(usuario, 'VER', ancla...).
--   - Resultados acotados al establecimiento del ancla (fn_grupo_
--     establecimiento) -- no al propio docente: es una biblioteca
--     institucional, para reusar lo que subio un colega del mismo colegio.
--   - Solo trae adaptaciones CON archivo (FK_TARCHIVO IS NOT NULL): un
--     enlace o una plantilla de biblioteca ya elegida no se "reutilizan",
--     se copian.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. La funcion.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION academico_test.fn_actividad_adaptaciones_reutilizables_listar(
    p_pk_usuario_solicitante BIGINT,
    p_pk_tactividad          BIGINT  DEFAULT NULL,
    p_fk_tasignatura         BIGINT  DEFAULT NULL,
    p_fk_tfuncionario        BIGINT  DEFAULT NULL,
    p_search                 VARCHAR DEFAULT NULL,
    p_pagina                 INTEGER DEFAULT 1,
    p_tamano_pagina          INTEGER DEFAULT 20,
    p_fk_tgrupo              BIGINT  DEFAULT NULL
)
RETURNS TABLE(
    fk_tarchivo             BIGINT,
    nombre_archivo          VARCHAR,
    peso                    BIGINT,
    pk_tactividad_origen    BIGINT,
    titulo_actividad_origen VARCHAR,
    fk_tlv_tipo_adaptacion  BIGINT,
    tipo_adaptacion         VARCHAR,
    descripcion             VARCHAR,
    total_count             BIGINT
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_limite INT;
    v_offset INT;
    v_grupo  BIGINT;
    v_ee     BIGINT;
BEGIN
    IF p_pk_tactividad IS NULL AND p_fk_tgrupo IS NULL THEN
        RAISE EXCEPTION 'Indique la actividad o el grupo para consultar la biblioteca de adaptaciones'
            USING ERRCODE = '22023',
                  HINT    = 'Al editar se manda la actividad; al crear, el grupo que ya eligio el formulario';
    END IF;

    PERFORM academico_test.fn_planeador_assert_alcance(
        p_pk_usuario_solicitante, 'VER',
        CASE WHEN p_pk_tactividad IS NULL THEN p_fk_tgrupo END,
        NULL, NULL, p_pk_tactividad
    );

    v_grupo := COALESCE(
        p_fk_tgrupo,
        (SELECT a.FK_TGRUPO FROM academico_test.TACTIVIDAD a
          WHERE a.PK_TACTIVIDAD = p_pk_tactividad)
    );
    v_ee := academico_test.fn_grupo_establecimiento(v_grupo);

    v_limite := GREATEST(COALESCE(p_tamano_pagina, 20), 1);
    v_offset := (GREATEST(COALESCE(p_pagina, 1), 1) - 1) * v_limite;

    RETURN QUERY
    SELECT t.PK_TARCHIVO,
           t.NOMBRE,
           t.PESO,
           a.PK_TACTIVIDAD,
           a.TITULO,
           ad.FK_TLV_TIPO_ADAPTACION,
           lv.NOMBRE,
           ad.DESCRIPCION,
           COUNT(*) OVER()
      FROM academico_test.TACTIVIDAD_ADAPTACION ad
      JOIN academico_test.TACTIVIDAD a  ON a.PK_TACTIVIDAD = ad.FK_TACTIVIDAD AND a.ACTIVE = TRUE
      JOIN academico_test.TARCHIVO t    ON t.PK_TARCHIVO = ad.FK_TARCHIVO AND t.ACTIVE = TRUE
      LEFT JOIN academico_test.TLISTA_VALOR lv ON lv.PK_LISTA_VALOR = ad.FK_TLV_TIPO_ADAPTACION
      -- Mismo camino que V429 para "de quien es": TACTIVIDAD no tiene un FK
      -- de funcionario propio, la unidad si (igual criterio, no inventado).
      LEFT JOIN academico_test.TUNIDAD u ON u.PK_TUNIDAD = a.FK_TUNIDAD
     WHERE ad.ACTIVE = TRUE
       AND ad.FK_TARCHIVO IS NOT NULL
       AND (p_pk_tactividad IS NULL OR a.PK_TACTIVIDAD <> p_pk_tactividad)
       AND (p_fk_tasignatura  IS NULL OR a.FK_TASIGNATURA = p_fk_tasignatura)
       AND (p_fk_tfuncionario IS NULL OR u.FK_TFUNCIONARIO = p_fk_tfuncionario)
       AND (v_ee IS NULL
            OR academico_test.fn_grupo_establecimiento(a.FK_TGRUPO) = v_ee)
       AND (p_search IS NULL OR TRIM(p_search) = ''
            OR t.NOMBRE ILIKE '%' || TRIM(p_search) || '%'
            OR a.TITULO ILIKE '%' || TRIM(p_search) || '%')
     ORDER BY t.NOMBRE, a.TITULO
     LIMIT v_limite
    OFFSET v_offset;
END;
$function$;

COMMENT ON FUNCTION academico_test.fn_actividad_adaptaciones_reutilizables_listar(BIGINT, BIGINT, BIGINT, BIGINT, VARCHAR, INTEGER, INTEGER, BIGINT)
    IS 'La "biblioteca institucional" de adaptaciones curriculares: plantillas (archivo) ya subidas en OTRAS actividades, para reusarlas sin volver a cargarlas. Mismo diseño que fn_actividad_materiales_reutilizables_listar (V429) -- ancla por actividad o grupo, gate fn_planeador_assert_alcance, resultados acotados al establecimiento del ancla, sin acotar al propio docente -- pero espejado directo en su forma final, sin la version previa "solo :ID" que V429 tuvo que arrastrar por compatibilidad. Solo trae adaptaciones CON archivo. Pagina con PAGINA (1-based) y SIZE, busca por nombre de archivo o titulo de la actividad de origen. V471.';


-- ---------------------------------------------------------------------------
-- 2. El endpoint.
-- ---------------------------------------------------------------------------
INSERT INTO public.query
    (uuid, query, type, public_end, captcha, microservice_id, path_template,
     execution_mode, http_method, param_types, out_param_names, detail, action, style)
SELECT
    'eval-col-adaptaciones-reutilizables-001',
    'SELECT * FROM academico_test.fn_actividad_adaptaciones_reutilizables_listar(
    public.fn_get_academico_usuario_id(:CONTEXT.USER_ID::BIGINT),
    CAST(:QUERY.ACTIVIDAD AS BIGINT),
    CAST(:QUERY.ASIGNATURA AS BIGINT),
    CAST(:QUERY.FUNCIONARIO AS BIGINT),
    CAST(:QUERY.SEARCH AS VARCHAR),
    COALESCE(CAST(:QUERY.PAGINA AS INT), 1),
    COALESCE(CAST(:QUERY.SIZE AS INT), 20),
    CAST(:QUERY.GRUPO AS BIGINT)
);',
    'postgres', false, false,
    m.id_microservice,
    '/planeador/adaptaciones-reutilizables', 'SELECT', 'GET',
    '{"QUERY.ACTIVIDAD": "BIGINT", "QUERY.GRUPO": "BIGINT", "QUERY.ASIGNATURA": "BIGINT", "QUERY.FUNCIONARIO": "BIGINT", "QUERY.SEARCH": "VARCHAR", "QUERY.PAGINA": "INT", "QUERY.SIZE": "INT"}'::jsonb,
    NULL,
    'Biblioteca institucional de adaptaciones: plantillas (archivo) subidas en otras actividades, para reusarlas. Hay que mandar ACTIVIDAD (al editar) o GRUPO (al crear); sin ninguno responde 22023. Los resultados se limitan al establecimiento de ese ancla. Solo trae adaptaciones CON archivo. Pagina con PAGINA (1-based) y SIZE, y busca por nombre de archivo o titulo de la actividad de origen.',
    'adaptaciones-reutilizables', 'DEFAULT'
  FROM public.microservice m
 WHERE m.serviceid = 'eval-col'
ON CONFLICT (microservice_id, path_template, http_method)
    WHERE path_template IS NOT NULL DO NOTHING;


-- ---------------------------------------------------------------------------
-- 3. Roles: los mismos que ya pueden reemplazar la lista de adaptaciones
--    (mismo criterio que V470 para /adaptaciones/archivo).
-- ---------------------------------------------------------------------------
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
