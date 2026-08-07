package com.co.eurekatic.query.catalog;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * Wire format of the {@code /getQuery} response. Mirrors
 * the legacy {@code sso-service} response shape (uppercase
 * JSON keys) so downstream consumers that already parsed
 * {@code Map<String,Object>} still work.
 *
 * <p>Fields we don't need (the bound role set, the
 * auto-increment id) are deliberately absent — the
 * catalog's authorization check is server-side, and the
 * query-service never inserts catalog rows.
 *
 * <p><b>V27</b> — {@code pathTemplate} is the URL suffix
 * within the microservice prefix. {@code query-service}'s
 * path-based dispatcher ({@code QueryPathRegistry}) uses it
 * to map incoming requests to the right uuid.
 *
 * <p><b>V28</b> — {@code executionMode} tells the JDBC
 * layer whether to run the row as SELECT / PROCEDURE /
 * FUNCTION. Defaults to {@code SELECT} if the catalog
 * didn't carry the field (pre-V28 server).
 *
 * <p><b>V31</b> — {@code outParamNames} is the
 * comma-separated list of {@code :placeholder} names that
 * are OUT params of a PROCEDURE-mode row. When present,
 * QueryService switches from JdbcTemplate.query to
 * CallableStatement and reads the OUT values into a
 * separate {@code outParams} map the controller returns
 * alongside the rows.
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
        @JsonProperty("outParamNames") String outParamNames
) {
    /**
     * Back-compat constructor for callers that pre-date V27/V28
     * (tests, mock setups, internal callers). Defaults
     * {@code pathTemplate=null} (legacy uuid-in-body flow),
     * {@code executionMode=SELECT} (legacy read query), and
     * {@code outParamNames=null} (no OUT params).
     */
    public QueryDefinition(Long idQuery, String uuid, String query,
                           String type, boolean publicEnd, boolean captcha,
                           String detail, String action, String style) {
        this(idQuery, uuid, query, type, publicEnd, captcha,
             detail, action, style, null, "SELECT", null);
    }

    /**
     * V27+V28 back-compat (no V31 outParamNames). Preserves
     * the 11-arg shape callers used between V27 and V31.
     */
    public QueryDefinition(Long idQuery, String uuid, String query,
                           String type, boolean publicEnd, boolean captcha,
                           String detail, String action, String style,
                           String pathTemplate, String executionMode) {
        this(idQuery, uuid, query, type, publicEnd, captcha,
             detail, action, style, pathTemplate, executionMode, null);
    }
}
