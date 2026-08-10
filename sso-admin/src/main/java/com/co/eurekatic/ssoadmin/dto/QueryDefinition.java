package com.co.eurekatic.ssoadmin.dto;

import com.co.eurekatic.common.entity.ExecutionMode;
import com.co.eurekatic.common.entity.Microservice;
import com.co.eurekatic.common.entity.Query;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Read-side response shape for {@code GET /getQuery?uuid=...}
 * and {@code GET /myQueries}. Consumed by both
 * {@code query-service} (per-uuid lookup) and the admin-ui
 * Queries Catalog page (list view).
 *
 * <p>This is the wire format — we deliberately do NOT include
 * the bound role set, because the consumer has no business with
 * them. The fields are an exact match to the legacy
 * {@code Map<String, Object>} returned by {@code sso-service}'s
 * {@code getOnlyQuery(...)} so the downstream {@code ReadService}
 * can deserialize the same shape it always did.
 *
 * <p>JSON keys mirror the legacy uppercase columns
 * ({@code ID_QUERY}, {@code QUERY}, {@code PUBLIC_END},
 * {@code CAPTCHA}, {@code TYPE}, {@code DETAIL}, {@code ACTION},
 * {@code STYLE}). Keeping the same names keeps the JSON
 * backward-compatible with any external consumer that already
 * parses the legacy response.
 *
 * <p>{@code microserviceId} tells the admin-ui which
 * {@code query-service-<instanceName>} gateway path to use when
 * executing the query. {@code null} means the query is "global"
 * and any instance may serve it (the UI defaults to the legacy
 * canonical {@code query-service} service id in that case).
 *
 * <p><b>V27</b> — {@code pathTemplate} surfaces the path suffix
 * so {@code query-service} can build its in-memory
 * {@code Map<pathTemplate, uuid>} registry for path-based
 * dispatch.
 *
 * <p><b>V28</b> — {@code executionMode} tells {@code query-service}
 * whether to run as SELECT / PROCEDURE / FUNCTION.
 */
public record QueryDefinition(
        Long idQuery,
        String uuid,
        String query,
        String type,
        boolean publicEnd,
        boolean captcha,
        String detail,
        String action,
        String style,
        Long microserviceId,
        String pathTemplate,
        ExecutionMode executionMode,
        String outParamNames,
        /** V33 — verbo HTTP: GET, POST o PUT. Default POST. */
        String httpMethod,
        /**
         * V49 — author-declared JDBC/PG type per caller-controlled
         * placeholder. Wire format: {@code {"PARAM.NOMBRE":"TEXT", ...}}.
         * Empty map when the row has no caller-controlled placeholders or
         * when the row is legacy (pre-V49 server doesn't carry it).
         */
        Map<String, String> paramTypes
) {
    /**
     * V31 — back-compat constructor for callers that pre-date
     * V27 + V28 + V31 (i.e. the 10-arg shape). The new fields
     * default to {@code null} / {@code SELECT} so legacy tests
     * keep compiling without a sweep.
     */
    public QueryDefinition(Long idQuery, String uuid, String query,
                           String type, boolean publicEnd, boolean captcha,
                           String detail, String action, String style,
                           Long microserviceId) {
        this(idQuery, uuid, query, type, publicEnd, captcha,
             detail, action, style, microserviceId,
             null, ExecutionMode.SELECT, null, null, new LinkedHashMap<>());
    }

    /**
     * V31 — back-compat for callers between V27 and V31
     * (10 args + pathTemplate, no executionMode / outParamNames).
     */
    public QueryDefinition(Long idQuery, String uuid, String query,
                           String type, boolean publicEnd, boolean captcha,
                           String detail, String action, String style,
                           Long microserviceId,
                           String pathTemplate, ExecutionMode executionMode) {
        this(idQuery, uuid, query, type, publicEnd, captcha,
             detail, action, style, microserviceId,
             pathTemplate, executionMode, null, null, new LinkedHashMap<>());
    }

    /**
     * V33 back-compat (no V49 paramTypes). Conserva la forma de 14
     * argumentos; el mapa cae a vacío para que el lado consumidor
     * (query-service) caiga en su rama "legacy" — Spring auto-derive.
     */
    public QueryDefinition(Long idQuery, String uuid, String query,
                           String type, boolean publicEnd, boolean captcha,
                           String detail, String action, String style,
                           Long microserviceId,
                           String pathTemplate, ExecutionMode executionMode,
                           String outParamNames, String httpMethod) {
        this(idQuery, uuid, query, type, publicEnd, captcha,
             detail, action, style, microserviceId,
             pathTemplate, executionMode, outParamNames, httpMethod,
             new LinkedHashMap<>());
    }

    public static QueryDefinition fromEntity(Query q) {
        Microservice m = q.getMicroservice();
        return new QueryDefinition(
                q.getId(),
                q.getUuid(),
                q.getQuery(),
                q.getType(),
                q.isPublicEnd(),
                q.isCaptcha(),
                q.getDetail(),
                q.getAction(),
                q.getStyle(),
                m != null ? m.getId() : null,
                q.getPathTemplate(),
                ExecutionMode.fromString(q.getExecutionMode()),
                q.getOutParamNames(),
                q.getHttpMethod(),
                q.getParamTypes());
    }
}
