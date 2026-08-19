-- V80 — envuelve las queries de escritura del catálogo de sso-admin (tabla
-- public.query) para que cada llamada fije app.request_id y funda 'path'
-- en app.contexto ANTES de invocar la función fn_* real, en la MISMA
-- sentencia/transacción -- necesario porque query-service no abre una
-- transacción explícita que abarque más de un statement (cada
-- jdbc.query()/jdbc.update() es su propio top-level statement), así que
-- un set_config() previo en un statement separado no sobreviviría hasta
-- el fn_* real. El MATERIALIZED fuerza a Postgres a computar el CTE
-- (y por tanto ejecutar los set_config) antes de evaluar la subconsulta
-- que llama a la función de escritura.
--
-- Requiere en paralelo el cambio de query-service (QueryService.
-- injectRequestParams(), commit "feat(query-service): inyectar
-- CONTEXT.REQUEST_ID/CONTEXT.PATH...") que agrega :CONTEXT.REQUEST_ID
-- (header X-Request-Id, o un UUID si no vino), :CONTEXT.PATH (método +
-- URI) y :CONTEXT.HTTP_METHOD (el método solo, para la columna propia de
-- ClickHouse) al mapa de parámetros de TODA petición -- sin ese cambio
-- estos placeholders llegarían NULL. El fragmento de app.http_method
-- requiere además que fn_audit_ctx() (V26) lo lea y lo emita en el
-- mensaje lógico — ver el cambio en V26__context-emitter.sql.
--
-- Es idempotente (el WHERE excluye filas que ya empiezan con el wrapper),
-- asi que corre segura tanto en un ambiente nuevo como en uno donde ya se
-- aplico manualmente antes de convertirse en migracion.
--
-- La lista de id_query es la de las 43 rutas de escritura registradas
-- localmente para las 49 funciones fn_* que adoptaron fn_audit_declarar
-- (ver docs/etiqueta-catalogo-funciones-fn.md); si el catálogo de otro
-- ambiente tiene ids distintos, regenerar la lista con:
--
--   SELECT id_query FROM public.query
--    WHERE query ~* 'academico_test\.fn_(area|subject|grupo|escala|periodo|
--                     descanso|criterio|plan|horario|asignacion|est|fun|
--                     sede|sed|usu|grado)_(crear|actualizar|soft_delete|
--                     guardar|eliminar|bulk|agregar)\(';

UPDATE public.query
SET query =
  'WITH _ctx AS MATERIALIZED (' || E'\n' ||
  '  SELECT set_config(''app.request_id'', :CONTEXT.REQUEST_ID, true) AS _rid,' || E'\n' ||
  '         set_config(''app.http_method'', :CONTEXT.HTTP_METHOD, true) AS _hm,' || E'\n' ||
  '         set_config(''app.contexto'', jsonb_build_object(''path'', :CONTEXT.PATH)::text, true) AS _c' || E'\n' ||
  ')' || E'\n' ||
  'SELECT _orig.* FROM _ctx, (' || regexp_replace(query, '\s*;\s*$', '') || ') AS _orig;'
WHERE id_query IN (
    28,29,30,31,33,34,35,39,40,41,43,44,46,47,48,51,55,57,58,60,61,62,
    65,66,67,75,76,77,78,82,85,90,91,92,93,95,99,100,106,108,110,118,133
)
  AND query NOT ILIKE 'WITH _ctx AS MATERIALIZED%';
