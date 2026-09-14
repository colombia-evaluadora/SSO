-- ============================================================================
-- V380 — "no se ven las operaciones de cada sesión": el detalle de una
-- sesión (/audits/sessions/:SESSIONID/operations) filtraba
-- `tabla LIKE 'academico_test.%'` (CEVAL) / `tabla LIKE 'pigse.%'` (PIGSE),
-- pero encontramos en vivo que `auditoria.audit_log.tabla` NO siempre
-- viene calificado con el esquema -- hay una cantidad grande de filas
-- (histórico Y actuales, verificado con una sesión de HOY) donde `tabla`
-- llega como solo 'tsede', 'tmatricula', 'tsesion_web', etc., sin el
-- prefijo 'academico_test.'/'pigse.'.
--
-- CAUSA RAÍZ (real, en cdc-worker, NO se toca en esta migración):
-- `academico_test.fn_audit_ctx()` (el trigger BEFORE STATEMENT) SIEMPRE
-- emite `TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME` correctamente
-- calificado en el mensaje lógico `audit_ctx`. Pero `AuditRecord.fromEvent`
-- (cdc-worker, pipeline/AuditRecord.java) arma el campo `tabla` del
-- registro final con `event.tableName()` -- que es SOLO
-- `CdcEvent.source().table()` (el nombre crudo de Debezium), sin
-- combinarlo nunca con `event.schemaName()`. Por qué coexisten filas
-- calificadas y sin calificar para la MISMA tabla es una pregunta más
-- profunda (probablemente una fusión con el mensaje audit_ctx que solo
-- a veces logra correlacionar) que queda pendiente como investigación
-- aparte -- no es proporcional resolver el pipeline completo de CDC
-- para arreglar "no veo las operaciones de mi sesión".
--
-- MITIGACIÓN ACOTADA Y SEGURA acá: esta query ya filtra por
-- `sesion_id = :PARAM.SESSIONID` -- una sesión pertenece a una sola app
-- (V377, app_name), así que CUALQUIER fila con ese sesion_id exacto es,
-- por construcción, de esa misma app, sin importar si a `tabla` le falta
-- el prefijo de esquema. Aflojar el filtro a "prefijo correcto O sin
-- ningún punto" es seguro AQUÍ porque el sesion_id ya es la clave real
-- de scoping -- a diferencia de /audit-tables/query y
-- /audit-tables/:SLUG/operations/query (V378/V379), que NO están
-- acotadas por sesión y de aflojarse igual arriesgarían mezclar
-- operaciones de CEVAL y PIGSE en tablas que existen con el mismo
-- nombre en ambos esquemas (tsede, tusuario, tfuncionario, etc.) --
-- esas dos quedan SIN tocar en esta migración, a propósito.
--
-- `tsesion_web` (login/logout) se deja VISIBLE a propósito: decisión de
-- producto confirmada explícitamente (no un descuido) -- la fila "Inicio
-- de sesión" es la primera entrada útil de la lista de operaciones de
-- una sesión.
-- ============================================================================

UPDATE public.query q
   SET query = replace(q.query, 'tabla LIKE ''academico_test.%''', '(tabla LIKE ''academico_test.%'' OR tabla NOT LIKE ''%.%'')')
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-cval'
   AND q.path_template = '/audits/sessions/:SESSIONID/operations'
   AND q.query LIKE '%tabla LIKE ''academico_test.%''%';

UPDATE public.query q
   SET query = replace(q.query, 'tabla LIKE ''pigse.%''', '(tabla LIKE ''pigse.%'' OR tabla NOT LIKE ''%.%'')')
  FROM public.microservice m
 WHERE m.id_microservice = q.microservice_id
   AND m.serviceid = 'audit-clickhouse-pigse'
   AND q.path_template = '/audits/sessions/:SESSIONID/operations'
   AND q.query LIKE '%tabla LIKE ''pigse.%''%';

DO $$
DECLARE
    v_cval_ok BOOLEAN;
    v_pigse_ok BOOLEAN;
BEGIN
    SELECT (q.query ILIKE '%tabla NOT LIKE ''%.%''%') INTO v_cval_ok
      FROM public.query q JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'audit-clickhouse-cval' AND q.path_template = '/audits/sessions/:SESSIONID/operations';

    SELECT (q.query ILIKE '%tabla NOT LIKE ''%.%''%') INTO v_pigse_ok
      FROM public.query q JOIN public.microservice m ON m.id_microservice = q.microservice_id
     WHERE m.serviceid = 'audit-clickhouse-pigse' AND q.path_template = '/audits/sessions/:SESSIONID/operations';

    IF NOT coalesce(v_cval_ok, false) OR NOT coalesce(v_pigse_ok, false) THEN
        RAISE EXCEPTION 'V380: no se aflojo el filtro de tabla en alguna de las dos filas (cval_ok=%, pigse_ok=%)', v_cval_ok, v_pigse_ok;
    END IF;

    RAISE NOTICE 'V380 OK: /audits/sessions/:SESSIONID/operations (cval + pigse) ahora tolera filas de audit_log con tabla sin prefijo de esquema.';
END $$;
