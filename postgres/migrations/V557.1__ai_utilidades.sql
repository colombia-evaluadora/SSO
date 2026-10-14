-- V557.1 -- Utilidades del agente: catalogo de herramientas y menus del usuario
-- Que hace: ai.fn_herramienta_catalogo_interno devuelve cada herramienta activa con su
--   ruta de eval-col (uuid y microservicio), restricciones y roles. ai.fn_menus_usuario_interno
--   devuelve los permisos por menu del usuario reutilizando academico_test.fn_usuario_permisos_menu;
--   ai.fn_funcionario_usuario_interno, su funcionario (fn_funcionario_actual).
-- Por que aqui: el servicio construye sus tools desde la allowlist ai.herramienta; los menus
--   se filtran en el agente solo como UX. Sin gate: la autoridad es el gate de cada ruta.
-- Depende de: V557 (ai.herramienta), V303 (fn_usuario_permisos_menu), V299 (fn_get_academico_usuario_id),
--   V224 (fn_funcionario_actual).

-- La columna detalle cambia el tipo de resultado: CREATE OR REPLACE no puede, hay que soltarla antes.
DROP FUNCTION IF EXISTS ai.fn_herramienta_catalogo_interno();

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
    roles                 TEXT[],
    detalle               TEXT
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
             WHERE rq.query_id = q.id_query),
           q.detail::TEXT
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
    'INTERNO: catalogo de herramientas activas del agente para el arranque del servicio. Une ai.herramienta con public.query por uuid y eval-col; devuelve restricciones, roles y el detail del endpoint (contrato para el modelo). Sin gate: la autoridad es el gate de cada ruta. Lo lee solo ai-control-service.';

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

-- Estructura esperada de cualquier herramienta, sacada del codigo que ejecuta su endpoint: sigue las
-- llamadas academico_test.fn_* desde public.query (3 niveles) y junta las claves JSON que leen (->> 'x')
-- y los mensajes de sus validaciones. Gates y alcance quedan fuera: no son estructura.
CREATE OR REPLACE FUNCTION ai.fn_herramienta_estructura_interno(p_herramienta_id BIGINT)
RETURNS TABLE (
    bloque       VARCHAR,
    claves       TEXT[],
    validaciones TEXT[]
)
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE fn (nombre, nivel) AS (
        SELECT DISTINCT lower(m[1]), 0
          FROM ai.herramienta h
          JOIN public.query q ON q.uuid = h.query_uuid,
               regexp_matches(q.query, 'academico_test\.(fn_[a-z0-9_]+)\s*\(', 'gi') m
         WHERE h.id = p_herramienta_id
        UNION
        SELECT DISTINCT lower(m[1]), f.nivel + 1
          FROM fn f
          JOIN pg_proc p ON p.proname = f.nombre
          JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'academico_test',
               regexp_matches(pg_get_functiondef(p.oid), 'academico_test\.(fn_[a-z0-9_]+)\s*\(', 'gi') m
         WHERE f.nivel < 3
    ), cuerpos AS (
        SELECT f.nombre, string_agg(pg_get_functiondef(p.oid), E'\n') AS def
          FROM (SELECT DISTINCT nombre FROM fn) f
          JOIN pg_proc p ON p.proname = f.nombre
          JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'academico_test'
         WHERE f.nombre !~ '(assert|permiso|alcance|gate|auditar|audit_|etiqueta|resolver_actor|categoria_rol)'
         GROUP BY f.nombre
    )
    SELECT regexp_replace(c.nombre, '^fn_|_interno$', '', 'g')::VARCHAR,
           ARRAY(SELECT DISTINCT k[1] FROM regexp_matches(c.def, '->>?\s*''([A-Za-z_][A-Za-z0-9_]*)''', 'g') k
                 ORDER BY 1),
           ARRAY(SELECT DISTINCT replace(replace(r[1], '''''', ''''), '%', '…')
                   FROM regexp_matches(c.def, 'RAISE\s+EXCEPTION\s+''((?:[^'']|'''')*)''', 'gi') r
                  ORDER BY 1)
      FROM cuerpos c
     WHERE c.def ~ '->>?\s*''[A-Za-z_]' OR c.def ~* 'RAISE\s+EXCEPTION'
     ORDER BY 1;
$$;

COMMENT ON FUNCTION ai.fn_herramienta_estructura_interno(BIGINT) IS
    'INTERNO: por bloque de codigo del endpoint de la herramienta, las claves JSON que lee y los mensajes de sus validaciones, recorriendo academico_test.fn_* desde public.query hasta 3 niveles. Generico para cualquier herramienta con ruta; sin gates. Lo usa la herramienta estructura_esperada del agente.';

CREATE OR REPLACE FUNCTION ai.fn_funcionario_usuario_interno(p_user_id BIGINT)
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT academico_test.fn_funcionario_actual(public.fn_get_academico_usuario_id(p_user_id));
$$;

COMMENT ON FUNCTION ai.fn_funcionario_usuario_interno(BIGINT) IS
    'INTERNO: pk_tfuncionario del usuario public.users p_user_id (NULL si no es funcionario), reutilizando academico_test.fn_funcionario_actual. El agente lo pone en los parametros de_sesion que el modelo no manda; el gate de la ruta sigue decidiendo.';

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
