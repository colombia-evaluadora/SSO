-- V556.1 -- ai.fn_herramienta_catalogo_interno: catalogo que el agente carga al arrancar
-- Que hace: devuelve cada herramienta activa con su ruta de eval-col (por uuid y
--   microservicio), sus restricciones de query_param_constraint y los roles de
--   role_query. Sin gate: no es endpoint; la autoridad es el gate de cada ruta.
-- Por que aqui: el servicio construye sus tools desde esta fuente y no desde
--   public.query directo, para que la allowlist de ai.herramienta sea la unica entrada.
-- Depende de: V556 (ai.herramienta), public.query, public.query_param_constraint, public.role_query.

CREATE OR REPLACE FUNCTION ai.fn_herramienta_catalogo_interno()
RETURNS TABLE (
    codigo               VARCHAR,
    tipo                 VARCHAR,
    descripcion_modelo   TEXT,
    parametros           JSONB,
    requiere_confirmacion BOOLEAN,
    ejemplos             JSONB,
    version              INTEGER,
    menu_codigo          VARCHAR,
    path_template        VARCHAR,
    http_method          VARCHAR,
    param_types          JSONB,
    restricciones        JSONB,
    roles                TEXT[]
)
LANGUAGE sql
STABLE
AS $$
    SELECT h.codigo::VARCHAR,
           h.tipo::VARCHAR,
           h.descripcion_modelo,
           h.parametros,
           h.requiere_confirmacion,
           h.ejemplos,
           h.version,
           h.menu_codigo::VARCHAR,
           q.path_template::VARCHAR,
           q.http_method::VARCHAR,
           q.param_types,
           (SELECT jsonb_object_agg(c.param_key,
                   jsonb_strip_nulls(to_jsonb(c) - 'id' - 'query_id' - 'param_key' - 'created_date'))
              FROM public.query_param_constraint c
             WHERE c.query_id = q.id_query),
           (SELECT array_agg(r.name::TEXT ORDER BY r.name)
              FROM public.role_query rq
              JOIN public.role r ON r.id_role = rq.role_id
             WHERE rq.query_id = q.id_query)
      FROM ai.herramienta h
      LEFT JOIN public.microservice ms ON ms.serviceid = 'eval-col'
      LEFT JOIN public.query q
             ON q.uuid = h.query_uuid
            AND q.microservice_id = ms.id_microservice
     WHERE h.active = TRUE
       AND (h.query_uuid IS NULL OR q.id_query IS NOT NULL)
     ORDER BY h.codigo;
$$;

COMMENT ON FUNCTION ai.fn_herramienta_catalogo_interno() IS
    'INTERNO: catalogo de herramientas activas del agente para el arranque del servicio. Une ai.herramienta con public.query por uuid y eval-col; devuelve restricciones y roles. Sin gate: la autoridad es el gate de cada ruta. Lo lee solo ai-control-service.';
