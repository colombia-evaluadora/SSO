-- ============================================================================
-- V376 — paginación real (servidor) para Auditoría, en vez del LIMIT 100
-- fijo documentado en V85 ("ClickHouse exige que LIMIT/OFFSET sean
-- constantes en el texto SQL, bindear falla con 'LIMIT expression must be
-- constant with numeric type'"). El front venía trayendo esa ventana de 100
-- filas y paginando/ordenando encima en el cliente (paginateWindow/
-- sortWindow, api/real-mapping.ts) -- mismo anti-patrón que ya se corrigió
-- en Monitoreo y Cumplimiento / Gestión Documental para PIGSE, esta vez
-- también para CEVAL (el motor es compartido).
--
-- CONTRAPARTE JAVA (query-service, QueryService.java,
-- substituteClickHouseLimitOffset): para las filas type='clickhouse' que
-- referencien :BODY.PAGESIZE/:BODY.PAGEOFFSET, esos dos placeholders se
-- sustituyen como ENTEROS LITERALES en el texto SQL (nunca bind normal,
-- que es justo lo que ClickHouse rechaza) y se retiran de los parámetros
-- antes de llegar al resto del pipeline. BODY.PAGEOFFSET es una clave
-- DERIVADA (pageIndex*pageSize) -- el cliente sigue mandando pageIndex/
-- pageSize como siempre, nunca un offset directo. Sin este cambio de
-- código, esta migración por sí sola no alcanza -- el SQL nuevo referencia
-- placeholders que el binder actual seguiría intentando bindear, y
-- ClickHouse los rechazaría igual que rechazaba ':BODY.PAGESIZE' antes de
-- V-ch-pag si se hubiera usado sin la sustitución literal.
--
-- `count() OVER() AS totalCount` YA estaba en las 8 filas (V85/V86/V90) y
-- YA daba el total real (los window functions de ClickHouse se computan
-- sobre todo el resultado que matchea el WHERE, antes del LIMIT final,
-- igual que en Postgres) -- el front simplemente lo descartaba y
-- recalculaba el suyo sobre la ventana de 100. Con paginación real,
-- ese totalCount pasa a ser el que hay que usar tal cual.
--
-- FUERA DE ALCANCE (documentado, no un olvido): el ORDER BY sigue siendo
-- fijo (por fecha descendente) -- hacerlo dinámico requeriría un mecanismo
-- de sustitución literal validado contra una allowlist de columnas por
-- fila, que es un cambio más grande y no es lo que se reportó ("la
-- paginación está en el front"). El front sigue re-ordenando client-side
-- SOLO dentro de la página ya traída del servidor -- que ahora sí es una
-- página real, no toda la ventana de 100.
-- ============================================================================

UPDATE public.query
   SET query = regexp_replace(query, 'LIMIT 100;\s*$', 'LIMIT :BODY.PAGESIZE OFFSET :BODY.PAGEOFFSET;')
 WHERE uuid IN (
     -- audit-clickhouse-cval
     '5fb89256-5f82-4c48-8d2a-cfec9862eba5', -- /audit-tables/:SLUG/operations/query
     '38ce8c17-d2dc-46bc-aa47-268b4d96e3a1', -- /audit-tables/query
     '8aa92343-8303-49c7-a5e5-3e5f54c1efe2', -- /audits/query
     'b33f21f3-4e06-41ec-bccc-7f076b547dab', -- /audits/sessions/:SESSIONID/operations
     -- audit-clickhouse-pigse
     '1a9366f9-5c16-4b70-afb1-4f26f27cb196', -- /audit-tables/:SLUG/operations/query
     '374c2d4c-b4b0-49fe-8aba-d3a86ef0273e', -- /audit-tables/query
     'c8df424d-952b-4a67-9012-3afc03b93166', -- /audits/query
     '43e8b116-c1b0-4731-82f7-10a4d133abbd'  -- /audits/sessions/:SESSIONID/operations
 )
   AND query ~ 'LIMIT 100;\s*$';

DO $$
DECLARE
    v_updated BIGINT;
BEGIN
    SELECT count(*) INTO v_updated
      FROM public.query
     WHERE uuid IN (
         '5fb89256-5f82-4c48-8d2a-cfec9862eba5', '38ce8c17-d2dc-46bc-aa47-268b4d96e3a1',
         '8aa92343-8303-49c7-a5e5-3e5f54c1efe2', 'b33f21f3-4e06-41ec-bccc-7f076b547dab',
         '1a9366f9-5c16-4b70-afb1-4f26f27cb196', '374c2d4c-b4b0-49fe-8aba-d3a86ef0273e',
         'c8df424d-952b-4a67-9012-3afc03b93166', '43e8b116-c1b0-4731-82f7-10a4d133abbd'
     )
       AND query ILIKE '%:BODY.PAGESIZE OFFSET :BODY.PAGEOFFSET%';

    IF v_updated != 8 THEN
        RAISE EXCEPTION 'V376 fallo: se esperaban 8 filas con LIMIT/OFFSET dinamico, se encontraron %', v_updated;
    END IF;

    RAISE NOTICE 'V376 OK: 8 queries de auditoria (CEVAL + PIGSE) con LIMIT/OFFSET dinamico. Requiere el deploy de query-service con substituteClickHouseLimitOffset para funcionar -- sin eso, ClickHouse rechazaria el bind de estos dos placeholders igual que antes.';
END $$;
