package com.co.eurekatic.ssoadmin.dto;

import com.co.eurekatic.common.entity.Microservice;
import com.co.eurekatic.common.entity.Query;

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
 * <p>{@code microserviceId} is NEW — it tells the admin-ui which
 * {@code query-service-<instanceName>} gateway path to use when
 * executing the query. {@code null} means the query is "global"
 * and any instance may serve it (the UI defaults to the legacy
 * canonical {@code query-service} service id in that case).
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
        Long microserviceId
) {
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
                m != null ? m.getId() : null);
    }
}
