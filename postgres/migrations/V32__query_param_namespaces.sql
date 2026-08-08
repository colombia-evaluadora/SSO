-- =============================================================================
-- V32 — namespaces de parámetros y sintaxis :VARIABLE en path templates.
--
-- Reescribe los datos existentes para la nueva gramática:
--
--   PATH_TEMPLATE  /establecimiento/{nombre}  ->  /establecimiento/:NOMBRE
--   QUERY (SQL)    ... like :nombre           ->  ... like :PARAM.NOMBRE
--                  :caller_user_id            ->  :CONTEXT.USER_ID
--
-- Es un cambio con ruptura y se hace ahora a propósito: el 2026-08-07 el
-- catálogo tenía 5 filas y sólo una con PATH_TEMPLATE. Con cincuenta filas
-- esto ya no sería barato.
--
-- El orden importa: la reescritura del path va antes que la del SQL, porque
-- la segunda lee los nombres de variable de la plantilla YA convertida.
-- =============================================================================

-- 1. Plantillas: {nombre} -> :nombre  (la caja se arregla en el paso 2)
UPDATE QUERY
SET PATH_TEMPLATE = regexp_replace(
        PATH_TEMPLATE, '\{([A-Za-z_][A-Za-z0-9_]*)\}', ':\1', 'g')
WHERE PATH_TEMPLATE IS NOT NULL
  AND PATH_TEMPLATE LIKE '%{%';

-- 2. Nombres de variable a MAYÚSCULA, dejando intactos los segmentos
--    literales de la ruta. Se reconstruye segmento a segmento en vez de
--    con un upper() global, que destrozaría /Establecimiento/:nombre.
UPDATE QUERY q
SET PATH_TEMPLATE = rebuilt.tpl
FROM (
    SELECT src.ID_QUERY AS id,
           '/' || string_agg(
                    CASE WHEN seg LIKE ':%' THEN upper(seg) ELSE seg END,
                    '/' ORDER BY ord) AS tpl
      FROM (SELECT ID_QUERY, PATH_TEMPLATE
              FROM QUERY
             WHERE PATH_TEMPLATE IS NOT NULL) src,
           LATERAL regexp_split_to_table(
                    ltrim(src.PATH_TEMPLATE, '/'), '/')
                   WITH ORDINALITY AS s(seg, ord)
     GROUP BY src.ID_QUERY
) AS rebuilt
WHERE q.ID_QUERY = rebuilt.id
  AND q.PATH_TEMPLATE IS DISTINCT FROM rebuilt.tpl;

-- 3. Binds de las variables de ruta en el SQL: :nombre -> :PARAM.NOMBRE
--    Sólo se tocan los nombres que son variables de ESA plantilla; un
--    :otro_bind que no aparezca en la ruta se deja intacto. La sustitución
--    necesita iterar los nombres fila a fila, cosa que un UPDATE plano no
--    expresa bien, así que va en un bloque procedural.
DO $$
DECLARE
    r        RECORD;
    var_name TEXT;
    new_sql  TEXT;
BEGIN
    FOR r IN
        SELECT ID_QUERY, PATH_TEMPLATE, QUERY
          FROM QUERY
         WHERE PATH_TEMPLATE IS NOT NULL
    LOOP
        new_sql := r.QUERY;
        FOR var_name IN
            SELECT upper(substring(seg FROM 2))
              FROM regexp_split_to_table(r.PATH_TEMPLATE, '/') AS seg
             WHERE seg LIKE ':%'
        LOOP
            -- \m y \M son límites de palabra en Postgres. Sin ellos,
            -- :id reescribiría también el prefijo de :identificador.
            new_sql := regexp_replace(
                new_sql,
                ':\m' || var_name || '\M',
                ':PARAM.' || var_name,
                'gi');
        END LOOP;
        IF new_sql IS DISTINCT FROM r.QUERY THEN
            UPDATE QUERY SET QUERY = new_sql WHERE ID_QUERY = r.ID_QUERY;
        END IF;
    END LOOP;
END $$;

-- 4. Contexto del llamante: caller_* -> CONTEXT.*
--    ROLES_ARRAY va ANTES que ROLES: si no, el prefijo común corrompe el
--    nombre largo y :caller_roles_array acabaría como :CONTEXT.ROLES_array.
UPDATE QUERY SET QUERY = replace(QUERY, ':caller_roles_array', ':CONTEXT.ROLES_ARRAY')
 WHERE QUERY LIKE '%:caller_roles_array%';
UPDATE QUERY SET QUERY = replace(QUERY, ':caller_user_id', ':CONTEXT.USER_ID')
 WHERE QUERY LIKE '%:caller_user_id%';
UPDATE QUERY SET QUERY = replace(QUERY, ':caller_email', ':CONTEXT.EMAIL')
 WHERE QUERY LIKE '%:caller_email%';
UPDATE QUERY SET QUERY = replace(QUERY, ':caller_roles', ':CONTEXT.ROLES')
 WHERE QUERY LIKE '%:caller_roles%';

-- 5. FUNCTION deja de existir como modo: se ejecutaba y validaba igual que
--    SELECT, así que la conversión es exacta, no una aproximación.
UPDATE QUERY SET EXECUTION_MODE = 'SELECT' WHERE EXECUTION_MODE = 'FUNCTION';

-- 6. TYPE (el dialecto) se hereda del microservicio dueño cuando falte.
UPDATE QUERY q
SET TYPE = m.DIALECT
FROM MICROSERVICE m
WHERE q.MICROSERVICE_ID = m.ID_MICROSERVICE
  AND m.DIALECT IS NOT NULL
  AND (q.TYPE IS NULL OR q.TYPE = '');

COMMENT ON COLUMN QUERY.PATH_TEMPLATE IS
    'Ruta dentro del microservicio con variables :MAYUSCULA (ej /establecimiento/:NOMBRE). Componer con MICROSERVICE.REQUEST_URI para la URL completa. Los valores se bindean como :PARAM.<VARIABLE>. NULL = solo accesible via POST /<svc>/query (legacy).';
