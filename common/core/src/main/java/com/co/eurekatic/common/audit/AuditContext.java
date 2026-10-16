package com.co.eurekatic.common.audit;

import java.util.Map;

/**
 * Contexto HTTP de una petición, capturado para viajar como GUCs de sesión
 * (`app.request_id`, `app.http_method`, `app.client_ip`, `app.user_agent`,
 * `app.headers`, `app.request_body`) hacia {@code academico_test.fn_audit_ctx()}
 * (ver {@code postgres/migrations/V26__context-emitter.sql}).
 *
 * <p>Mismos siete campos que query-service ya inyecta en
 * {@code :CONTEXT.*} vía {@code QueryService.injectRequestParams} — este
 * record es la forma "objeto de valor" del mismo dato, para callers que
 * fijan las GUCs con {@code jdbc.queryForList("SELECT set_config(...)")}
 * en vez de sustituirlas en SQL dinámico de catálogo.
 *
 * @see AuditContextExtractor#fromCurrentRequest(Map)
 */
public record AuditContext(
        String requestId,
        String httpMethod,
        String clientIp,
        String userAgent,
        Map<String, String> headers,
        String requestBodyJson
) {}
