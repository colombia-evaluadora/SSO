-- V557.1 -- Utilidades del agente: catalogo de herramientas y menus del usuario
-- Que hace: ai.fn_herramienta_catalogo_interno devuelve cada herramienta activa con su
--   ruta de eval-col (uuid y microservicio), restricciones y roles. ai.fn_menus_usuario_interno
--   devuelve los permisos por menu del usuario reutilizando academico_test.fn_usuario_permisos_menu.
-- Por que aqui: el servicio construye sus tools desde la allowlist ai.herramienta; los menus
--   se filtran en el agente solo como UX. Sin gate: la autoridad es el gate de cada ruta.
-- Depende de: V557 (ai.herramienta), V303 (fn_usuario_permisos_menu), V299 (fn_get_academico_usuario_id).

CREATE OR REPLACE FUNCTION ai.fn_herramienta_catalogo_interno()
RETURNS TABLE (
    id                    BIGINT,
    codigo                VARCHAR,
    tipo                  VARCHAR,
    descripcion_modelo    TEXT,
    parametros            JSONB,
    requiere_confirmacion BOOLEAN,
    aviso_confirmacion    TEXT,
    ejemplos              JSONB,
    version               INTEGER,
    menu_codigo           VARCHAR,
    path_template         VARCHAR,
    http_method           VARCHAR,
    param_types           JSONB,
    restricciones         JSONB,
    roles                 TEXT[]
)
LANGUAGE sql
STABLE
AS $$
    SELECT h.id,
           h.codigo::VARCHAR,
           h.tipo::VARCHAR,
           h.descripcion_modelo,
           h.parametros,
           h.requiere_confirmacion,
           h.aviso_confirmacion,
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

-- p_user_id es public.users.id (claim uid del JWT). Sin usuario academico, el puente devuelve NULL.
CREATE OR REPLACE FUNCTION ai.fn_menus_usuario_interno(p_user_id BIGINT)
RETURNS TABLE (
    codigo         VARCHAR,
    puede_ver      BOOLEAN,
    puede_crear    BOOLEAN,
    puede_editar   BOOLEAN,
    puede_eliminar BOOLEAN
)
LANGUAGE sql
STABLE
AS $$
    SELECT p.codigo::VARCHAR,
           p.puede_ver,
           p.puede_crear,
           p.puede_editar,
           p.puede_eliminar
      FROM academico_test.fn_usuario_permisos_menu(public.fn_get_academico_usuario_id(p_user_id)) p;
$$;

COMMENT ON FUNCTION ai.fn_menus_usuario_interno(BIGINT) IS
    'INTERNO: permisos por menu (ver, crear, editar, eliminar) del usuario public.users p_user_id, reutilizando academico_test.fn_usuario_permisos_menu. El filtro por menus del agente es UX; la autoridad es el gate de cada ruta.';

CREATE OR REPLACE FUNCTION ai.fn_pantallas_interno()
RETURNS TABLE (
    codigo       VARCHAR,
    menu_codigo  VARCHAR,
    nombre       VARCHAR,
    url          VARCHAR,
    menu_padre   VARCHAR,
    descripcion  TEXT,
    sinonimos    TEXT[]
)
LANGUAGE sql
STABLE
AS $$
    SELECT r.codigo::VARCHAR,
           m.codigo::VARCHAR,
           m.nombre::VARCHAR,
           (m.url || COALESCE(r.ruta_sufijo, ''))::VARCHAR,
           p.nombre::VARCHAR,
           r.descripcion,
           r.sinonimos
      FROM ai.ruta_ui r
      JOIN academico_test.tmenu m ON m.codigo = r.menu_codigo AND m.active = TRUE
      LEFT JOIN academico_test.tmenu p ON p.pk_tmenu = m.fk_tmenu AND p.active = TRUE
     WHERE r.active = TRUE
       AND NULLIF(m.url, '') IS NOT NULL
     ORDER BY p.nombre NULLS FIRST, m.nombre;
$$;

COMMENT ON FUNCTION ai.fn_pantallas_interno() IS
    'INTERNO: pantallas que el agente puede indicar (buscar_pantalla): ai.ruta_ui con nombre, URL y menu padre de TMENU. Sin filtro de usuario: el servicio las cruza con ai.fn_menus_usuario_interno y nunca indica una pantalla sin acceso.';

CREATE OR REPLACE FUNCTION ai.fn_formularios_ui_interno()
RETURNS TABLE (
    codigo                VARCHAR,
    menu_codigo           VARCHAR,
    origen                VARCHAR,
    campos_fuente         VARCHAR,
    herramienta_escritura VARCHAR
)
LANGUAGE sql
STABLE
AS $$
    SELECT f.codigo::VARCHAR,
           r.menu_codigo::VARCHAR,
           f.origen::VARCHAR,
           f.campos_fuente::VARCHAR,
           h.codigo::VARCHAR
      FROM ai.ui_formulario f
      JOIN ai.ruta_ui r ON r.id = f.ruta_ui_id AND r.active = TRUE
      LEFT JOIN ai.herramienta h ON h.id = f.herramienta_escritura AND h.active = TRUE
     WHERE f.active = TRUE
     ORDER BY f.codigo;
$$;

COMMENT ON FUNCTION ai.fn_formularios_ui_interno() IS
    'INTERNO: registro de formularios que el agente puede rellenar. En origen DB, campos_fuente es el codigo de la herramienta de lectura que da la configuracion de campos con el gate del usuario.';
