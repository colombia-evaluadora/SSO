package com.co.eurekatic.query.catalog;

import com.co.eurekatic.common.query.ParamConstraint;
import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.Map;

/**
 * Wire format of the {@code /getQuery} response — one {@code public.query}
 * row as sso-admin publishes it.
 *
 * <p>Fields we don't need (the bound role set, the auto-increment id)
 * are deliberately absent — the catalog's authorization check is
 * server-side, and the query-service never inserts catalog rows.
 *
 * <ul>
 *   <li>{@code pathTemplate} — URL suffix within the microservice
 *       prefix; {@code QueryPathRegistry} maps incoming requests to
 *       the uuid with it. Null for uuid-in-body rows.</li>
 *   <li>{@code executionMode} — SELECT / FUNCTION / PROCEDURE / DML;
 *       null means SELECT.</li>
 *   <li>{@code outParamNames} — comma-separated OUT placeholders of a
 *       PROCEDURE row; when present, QueryService uses a
 *       CallableStatement and returns them under {@code outParams}.</li>
 *   <li>{@code httpMethod} — GET / POST / PUT / PATCH; null means POST.</li>
 *   <li>{@code paramTypes} — {@code {"PARAM.NOMBRE":"TEXT",
 *       "BODY.IDS":"BIGINT[]", "BODY.ID":"BIGINT!"}}; the author-declared
 *       PG type per caller-controlled placeholder ({@code '!'} marks
 *       it required). Null/empty = legacy row bound without casts.</li>
 *   <li>{@code paramConstraints} — optional format rules per
 *       placeholder, on top of {@code paramTypes}.</li>
 *   <li>{@code cacheable} / {@code cacheTtlSeconds} — opt-in Redis
 *       cache for GET rows.</li>
 * </ul>
 */
@JsonIgnoreProperties(ignoreUnknown = true)
public record QueryDefinition(
        @JsonProperty("idQuery") Long idQuery,
        @JsonProperty("uuid") String uuid,
        @JsonProperty("query") String query,
        @JsonProperty("type") String type,
        @JsonProperty("publicEnd") boolean publicEnd,
        @JsonProperty("captcha") boolean captcha,
        @JsonProperty("detail") String detail,
        @JsonProperty("action") String action,
        @JsonProperty("style") String style,
        @JsonProperty("pathTemplate") String pathTemplate,
        @JsonProperty("executionMode") String executionMode,
        @JsonProperty("outParamNames") String outParamNames,
        @JsonProperty("httpMethod") String httpMethod,
        @JsonProperty("paramTypes") Map<String, String> paramTypes,
        @JsonProperty("paramConstraints") Map<String, ParamConstraint> paramConstraints,
        @JsonProperty("cacheable") boolean cacheable,
        @JsonProperty("cacheTtlSeconds") int cacheTtlSeconds
) {
    /**
     * Without paramConstraints / cacheable / cacheTtlSeconds: a catalog
     * server that doesn't send those fields falls to the safe defaults
     * (no extra constraints, no caching).
     */
    public QueryDefinition(Long idQuery, String uuid, String query,
                           String type, boolean publicEnd, boolean captcha,
                           String detail, String action, String style,
                           String pathTemplate, String executionMode,
                           String outParamNames, String httpMethod,
                           Map<String, String> paramTypes) {
        this(idQuery, uuid, query, type, publicEnd, captcha,
             detail, action, style, pathTemplate, executionMode,
             outParamNames, httpMethod, paramTypes, null, false, 60);
    }

    /** Uuid-in-body SELECT row: no path template, POST, no typed params. */
    public QueryDefinition(Long idQuery, String uuid, String query,
                           String type, boolean publicEnd, boolean captcha,
                           String detail, String action, String style) {
        this(idQuery, uuid, query, type, publicEnd, captcha,
             detail, action, style, null, "SELECT", null, "POST", null);
    }

    /** Path template + execution mode; POST, no OUT params, no typed params. */
    public QueryDefinition(Long idQuery, String uuid, String query,
                           String type, boolean publicEnd, boolean captcha,
                           String detail, String action, String style,
                           String pathTemplate, String executionMode) {
        this(idQuery, uuid, query, type, publicEnd, captcha,
             detail, action, style, pathTemplate, executionMode, null, "POST", null);
    }

    /** With OUT params; POST, no typed params. */
    public QueryDefinition(Long idQuery, String uuid, String query,
                           String type, boolean publicEnd, boolean captcha,
                           String detail, String action, String style,
                           String pathTemplate, String executionMode,
                           String outParamNames) {
        this(idQuery, uuid, query, type, publicEnd, captcha,
             detail, action, style, pathTemplate, executionMode,
             outParamNames, "POST", null);
    }

    /** With HTTP method; no typed params. */
    public QueryDefinition(Long idQuery, String uuid, String query,
                           String type, boolean publicEnd, boolean captcha,
                           String detail, String action, String style,
                           String pathTemplate, String executionMode,
                           String outParamNames, String httpMethod) {
        this(idQuery, uuid, query, type, publicEnd, captcha,
             detail, action, style, pathTemplate, executionMode,
             outParamNames, httpMethod, null);
    }
}
