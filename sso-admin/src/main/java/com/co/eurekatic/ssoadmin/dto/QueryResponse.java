package com.co.eurekatic.ssoadmin.dto;

import com.co.eurekatic.common.entity.ExecutionMode;
import com.co.eurekatic.common.entity.Microservice;
import com.co.eurekatic.common.entity.Query;
import com.co.eurekatic.common.query.ParamConstraint;

import java.time.LocalDateTime;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * Response shape for the query CRUD endpoints. Includes the
 * bound role ids so the admin UI can render the multi-select
 * without a follow-up round-trip — same pattern as
 * {@link EndpointResponse}.
 *
 * <p>{@code createdDate} is the DB-managed timestamp
 * (insertable=false, updatable=false on the entity). We surface
 * it for the admin UI; {@code query-service} ignores it.
 *
 * <p>{@code microserviceId} identifies the {@code query-service-<instance>}
 * that owns this query. Surfaced for the admin CRUD form so
 * operators can re-bind a query to a different instance without
 * writing SQL.
 *
 * <p><b>V27</b> — {@code pathTemplate} is the URL suffix this
 * query exposes within the microservice's prefix. Nullable for
 * legacy queries that only respond to the uuid-in-body flow.
 *
 * <p><b>V28</b> — {@code executionMode} tells {@code query-service}
 * how to run the SQL.
 */
public record QueryResponse(
        Long id,
        String uuid,
        String query,
        String type,
        boolean publicEnd,
        boolean captcha,
        String detail,
        String action,
        String style,
        LocalDateTime createdDate,
        Set<Long> roleIds,
        Long microserviceId,
        String pathTemplate,
        ExecutionMode executionMode,
        String outParamNames,
        /** V33 — verbo HTTP: GET, POST o PUT. Default POST. */
        String httpMethod,
        /**
         * V49 — author-declared JDBC/PG type per caller-controlled
         * placeholder. Shape: {@code {"PARAM.NOMBRE":"TEXT", ...}}.
         * Empty map means the row is legacy or has no caller-controlled
         * placeholders.
         */
        Map<String, String> paramTypes,
        /**
         * V81 — restricciones de formato opcionales por placeholder.
         * Ver {@code Query#getParamConstraints()} y
         * {@code ParamConstraint}. Empty map = sin restricciones
         * adicionales.
         */
        Map<String, ParamConstraint> paramConstraints
) {
    public static QueryResponse fromEntity(Query q) {
        Microservice m = q.getMicroservice();
        Map<String, ParamConstraint> constraints = new LinkedHashMap<>();
        for (var c : q.getParamConstraints()) {
            constraints.put(c.getParamKey(), new ParamConstraint(
                    c.getOnlyPositive(), c.getAllowDecimals(), c.getMaxDigits(),
                    c.getMinValue(), c.getMaxValue(),
                    c.getNumericText(), c.getMinLength(), c.getMaxLength()));
        }
        return new QueryResponse(
                q.getId(),
                q.getUuid(),
                q.getQuery(),
                q.getType(),
                q.isPublicEnd(),
                q.isCaptcha(),
                q.getDetail(),
                q.getAction(),
                q.getStyle(),
                q.getCreatedDate(),
                q.getRoles().stream()
                        .map(com.co.eurekatic.common.entity.Role::getId)
                        .collect(Collectors.toCollection(LinkedHashSet::new)),
                m != null ? m.getId() : null,
                q.getPathTemplate(),
                ExecutionMode.fromString(q.getExecutionMode()),
                q.getOutParamNames(),
                q.getHttpMethod(),
                q.getParamTypes(),
                constraints);
    }
}
