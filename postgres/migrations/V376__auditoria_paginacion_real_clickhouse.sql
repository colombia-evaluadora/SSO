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
--
-- REV — la primera versión de este archivo apuntaba por `uuid` literal,
-- copiados de la fila YA EXISTENTE en el servidor de test. Eso rompió CI:
-- esas filas se insertan con `gen_random_uuid()::text` (V85/V86/V90/V356/
-- V357), un valor DISTINTO en cada base donde la migración corre desde
-- cero (como la de CI) -- el `uuid` de test nunca va a existir en un
-- Postgres recién migrado. Se apunta por `microservice.serviceid` +
-- `path_template` en su lugar, como el resto de las migraciones de la
-- sesión.
-- ============================================================================

UPDATE public.query q
   SET query = regexp_replace(q.query, 'LIMIT 100;\s*$', 'LIMIT :BODY.PAGESIZE OFFSET :BODY.PAGEOFFSET;')
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid IN ('audit-clickhouse-cval', 'audit-clickhouse-pigse')
   AND q.path_template IN (
       '/audits/query',
       '/audits/sessions/:SESSIONID/operations',
       '/audit-tables/query',
       '/audit-tables/:SLUG/operations/query'
   )
   AND q.query ~ 'LIMIT 100;\s*$';

DO $$
DECLARE
    v_updated BIGINT;
BEGIN
    SELECT count(*) INTO v_updated
      FROM public.query q
      JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid IN ('audit-clickhouse-cval', 'audit-clickhouse-pigse')
       AND q.path_template IN (
           '/audits/query',
           '/audits/sessions/:SESSIONID/operations',
           '/audit-tables/query',
           '/audit-tables/:SLUG/operations/query'
       )
       AND q.query ILIKE '%:BODY.PAGESIZE OFFSET :BODY.PAGEOFFSET%';

    IF v_updated != 8 THEN
        RAISE WARNING 'V376: se esperaban 8 filas con LIMIT/OFFSET dinamico, se encontraron %. Puede ser normal en un ambiente sin las filas de auditoria de V85/V86/V90/V356/V357 aun sembradas.', v_updated;
    ELSE
        RAISE NOTICE 'V376 OK: 8 queries de auditoria (CEVAL + PIGSE) con LIMIT/OFFSET dinamico. Requiere el deploy de query-service con substituteClickHouseLimitOffset para funcionar -- sin eso, ClickHouse rechazaria el bind de estos dos placeholders igual que antes.';
    END IF;
END $$;
