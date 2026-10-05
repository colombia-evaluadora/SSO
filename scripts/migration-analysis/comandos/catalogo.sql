-- Catalogo real de una base con todas las migraciones aplicadas: lo que
-- oraculo.py compara contra el modelo. Solo lectura.
\pset format unaligned
\pset tuples_only on
SELECT json_build_object(
 'functions', (SELECT json_agg(json_build_object('schema', n.nspname, 'name', p.proname,
                 'args', pg_get_function_identity_arguments(p.oid), 'src', p.prosrc))
   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_%'
     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')),
 'relations', (SELECT json_agg(json_build_object('schema', n.nspname, 'name', c.relname, 'kind', c.relkind))
   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
     AND c.relkind IN ('r', 'v', 'm', 'i', 'S', 'p')
     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')),
 'owned_sequences', (SELECT json_agg(n.nspname || '.' || c.relname)
   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relkind = 'S' AND EXISTS (SELECT 1 FROM pg_depend d
         WHERE d.objid = c.oid AND d.deptype IN ('a', 'i') AND d.refclassid = 'pg_class'::regclass)),
 'columns', (SELECT json_agg(json_build_object('schema', table_schema, 'table', table_name, 'col', column_name))
   FROM information_schema.columns WHERE table_schema NOT IN ('pg_catalog', 'information_schema')),
 'constraints', (SELECT json_agg(json_build_object('schema', n.nspname, 'table', c.relname,
                   'name', k.conname, 'type', k.contype))
   FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')),
 'triggers', (SELECT json_agg(json_build_object('schema', n.nspname, 'table', c.relname, 'name', t.tgname))
   FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE NOT t.tgisinternal),
 'schemas', (SELECT json_agg(nspname) FROM pg_namespace
   WHERE nspname NOT LIKE 'pg_%' AND nspname <> 'information_schema'),
 'extensions', (SELECT json_agg(extname) FROM pg_extension),
 'types', (SELECT json_agg(json_build_object('schema', n.nspname, 'name', t.typname))
   FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
   WHERE t.typtype IN ('d', 'e', 'c') AND n.nspname NOT IN ('pg_catalog', 'information_schema')
     AND n.nspname NOT LIKE 'pg_%'
     AND (t.typtype <> 'c' OR EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = t.typrelid AND c.relkind = 'c'))),
 'publications', (SELECT json_agg(pubname) FROM pg_publication),
 'query_rows', (SELECT json_agg(json_build_object('uuid', q.uuid, 'service', m.serviceid,
                  'path', q.path_template, 'method', q.http_method,
                  'roles', (SELECT count(*) FROM public.role_query rq WHERE rq.query_id = q.id_query)))
   FROM public.query q LEFT JOIN public.microservice m ON m.id_microservice = q.microservice_id)
);
