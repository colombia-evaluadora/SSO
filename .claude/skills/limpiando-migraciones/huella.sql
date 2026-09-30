-- Huella logica del esquema: lo que tiene que quedar igual tras un recorte.
-- Sin ids ni fechas, y sin \r (git archive en Windows saca CRLF: no es real).
\pset tuples_only on
\pset format unaligned

-- funciones: firma + definicion + comentario
SELECT 'fn|' || n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')|'
       || md5(replace(pg_get_functiondef(p.oid), chr(13), '')) || '|'
       || coalesce(md5(replace(obj_description(p.oid, 'pg_proc'), chr(13), '')), '-')
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND p.prokind IN ('f', 'p')
 ORDER BY 1;

-- indices
SELECT 'ix|' || schemaname || '.' || indexname || '|' || md5(indexdef)
  FROM pg_indexes WHERE schemaname <> 'pg_catalog' ORDER BY 1;

-- constraints
SELECT 'ck|' || n.nspname || '.' || c.relname || '|' || co.conname || '|' || md5(pg_get_constraintdef(co.oid))
  FROM pg_constraint co JOIN pg_class c ON c.oid = co.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') ORDER BY 1;

-- triggers
SELECT 'tg|' || n.nspname || '.' || c.relname || '|' || t.tgname || '|' || md5(pg_get_triggerdef(t.oid))
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE NOT t.tgisinternal ORDER BY 1;

-- columnas
SELECT 'col|' || table_schema || '.' || table_name || '.' || column_name || '|' || data_type || '|'
       || is_nullable || '|' || coalesce(column_default, '')
  FROM information_schema.columns
 WHERE table_schema NOT IN ('pg_catalog', 'information_schema') AND table_schema NOT LIKE 'pg_temp%'
 ORDER BY 1;

-- filas de public.query por ruta
SELECT 'q|' || coalesce(m.serviceid, '?') || '|' || q.path_template || '|' || q.http_method || '|'
       || md5(replace(coalesce(q.query, ''), chr(13), '')) || '|' || md5(coalesce(q.param_types::text, '')) || '|'
       || md5(replace(coalesce(q.detail, ''), chr(13), ''))
  FROM public.query q LEFT JOIN public.microservice m ON m.id_microservice = q.microservice_id
 ORDER BY 1;
