-- md5 del contenido de cada tabla, sin columnas de identidad, fks, fechas ni
-- auditoria. Detecta semillas, UPDATE y backfills que el recorte altero.
\pset tuples_only on
\pset format unaligned
DO $$
DECLARE r record; cols text; h text;
BEGIN
  CREATE TEMP TABLE _dat(l text);
  FOR r IN SELECT n.nspname s, c.relname t
             FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog', 'information_schema')
              AND n.nspname NOT LIKE 'pg_temp%' AND c.relname <> 'flyway_schema_history' LOOP
    SELECT string_agg(format('%I', a.attname), ',' ORDER BY a.attname) INTO cols
      FROM pg_attribute a
     WHERE a.attrelid = format('%I.%I', r.s, r.t)::regclass AND a.attnum > 0 AND NOT a.attisdropped
       AND a.attname !~* '^(pk_|id|fk_|uuid|fecha|created|modified|updated|last_|.*_at$|.*_id$)'
       AND a.atttypid <> 'bytea'::regtype;
    IF cols IS NULL THEN CONTINUE; END IF;
    EXECUTE format('SELECT md5(coalesce(string_agg(replace(x::text, chr(13), ''''), ''|'' ORDER BY x::text), '''')) '
                   'FROM (SELECT ROW(%s) x FROM %I.%I) q', cols, r.s, r.t) INTO h;
    INSERT INTO _dat VALUES ('d|' || r.s || '.' || r.t || '|' || h);
  END LOOP;
END $$;
SELECT l FROM _dat ORDER BY 1;
