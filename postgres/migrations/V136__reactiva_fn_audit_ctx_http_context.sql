-- =============================================================================
-- V136 — reactiva la definicion COMPLETA de academico_test.fn_audit_ctx
-- (V-audit-ctx-2/V-audit-ctx-3: client_ip, http_method, user_agent, headers,
-- request_body, app_user_id) en el servidor de pruebas, donde seguia corriendo
-- una version mas vieja del trigger sin esos campos.
--
-- SINTOMA
--   Las columnas nuevas de auditoria.audit_log (client_ip, headers,
--   request_body, http_method, user_agent, app_user_id -- agregadas hoy vía
--   ALTER TABLE para que el esquema coincida con
--   docker/clickhouse/clickhouse-init.sql) llegan SIEMPRE vacias/NULL, aunque
--   query-service SI las esta mandando (QueryService.wrapWithAuditContext ya
--   hace set_config('app.client_ip', ...), set_config('app.headers', ...),
--   etc. -- confirmado en el codigo, no es un gap del lado Java).
--
-- CAUSA (mismo patron que fn_resolver_actor, V53, V59 -- drift de servidor)
--   El ARCHIVO postgres/migrations/V26__context-emitter.sql YA tiene la
--   definicion completa de fn_audit_ctx con los 6 campos de contexto HTTP
--   (confirmado via `SELECT pg_get_functiondef` contra el codigo fuente).
--   Pero Flyway registra V26 como aplicada desde 2026-08-04 -- ANTES de que
--   esa version completa se escribiera en el archivo -- y un CREATE OR
--   REPLACE FUNCTION nunca se re-ejecuta solo porque el archivo cambio
--   despues; Flyway no vuelve a correr una version ya aplicada salvo que el
--   checksum no coincida (y en ese caso bloquea el deploy entero, no lo
--   arregla solo). El servidor se quedo con el fn_audit_ctx original de
--   spec §4.3 (solo tabla/op/app_user/db_user/sesion_id/familia/
--   request_id/etiqueta/contexto), sin los campos agregados despues.
--
--   cdc-worker YA espera estos campos por nombre exacto
--   (com.example.cdc.common.event.CdcEvent.Context: http_method, client_ip,
--   user_agent, headers, request_body, app_user_id) -- el comentario del
--   propio record dice literalmente "fn_audit_ctx los castea a json en
--   Postgres", confirmando que el codigo Java fue escrito asumiendo esta
--   version del trigger.
--
-- FIX
--   CREATE OR REPLACE FUNCTION con el texto vigente de V26 (idempotente).
--   NO se re-crean los triggers trg_audit_ctx: ya existen en las 148 tablas
--   de academico_test (creados por la corrida original de V26) y apuntan a
--   la funcion POR NOMBRE -- un REPLACE del cuerpo les llega automaticamente
--   en la siguiente transaccion, sin necesidad de recrear el trigger.
--
-- Idempotente: CREATE OR REPLACE FUNCTION, mismo patron que V58/V66/V121.
-- =============================================================================

CREATE OR REPLACE FUNCTION academico_test.fn_audit_ctx()
RETURNS TRIGGER AS $$
DECLARE
    v_ctx  json;
    v_etiq TEXT;
BEGIN
    v_ctx  := NULLIF(current_setting('app.contexto', true), '')::json;
    v_etiq := LEFT(NULLIF(current_setting('app.etiqueta', true), ''), 200);

    PERFORM pg_logical_emit_message(
        true,
        'audit_ctx',
        json_build_object(
            'tabla',       TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
            'op',          LEFT(TG_OP, 1),
            'app_user',    NULLIF(current_setting('app.user_id', true), ''),
            -- V-audit-ctx-3: PK numérico crudo del actor, además del nombre
            -- legible de arriba. fn_audit_declarar (V66) resuelve el nombre
            -- y SOBREESCRIBE app.user_id con él -- este campo aparte nunca
            -- se pisa, así que el PK sobrevive incluso cuando la resolución
            -- de nombre falla o el actor no existe en TUSUARIO.
            'app_user_id', NULLIF(current_setting('app.user_pk', true), ''),
            'db_user',     session_user,
            'sesion_id',   v_ctx ->> 'sesion_id',
            'familia',     v_ctx ->> 'familia',
            'request_id',  LEFT(NULLIF(current_setting('app.request_id', true), ''), 100),
            'http_method', LEFT(NULLIF(current_setting('app.http_method', true), ''), 10),
            -- V-audit-ctx-2: IP/user-agent/headers/body para auditoría de
            -- seguridad. headers/request_body llegan ya serializados como
            -- JSON (ver QueryService.injectRequestParams) así que se
            -- castean, no se truncan como los TEXT sueltos de arriba.
            'client_ip',    LEFT(NULLIF(current_setting('app.client_ip', true), ''), 45),
            'user_agent',   LEFT(NULLIF(current_setting('app.user_agent', true), ''), 500),
            'headers',      NULLIF(current_setting('app.headers', true), '')::json,
            'request_body', NULLIF(current_setting('app.request_body', true), '')::json,
            'etiqueta',    v_etiq,
            'contexto',    v_ctx
        )::text
    );
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION academico_test.fn_audit_ctx() IS
    'Trigger BEFORE STATEMENT en las 148 tablas de academico_test (V26): emite pg_logical_emit_message(''audit_ctx'', ...) con el contexto completo -- incluye V-audit-ctx-2 (client_ip, user_agent, headers, request_body) y V-audit-ctx-3 (app_user_id) ademas de los campos originales. Reactivada en V136 tras confirmar que el servidor de pruebas seguia con una version anterior sin estos campos (drift Flyway -- el archivo V26 se actualizo despues de que esa version quedara marcada como aplicada).';
