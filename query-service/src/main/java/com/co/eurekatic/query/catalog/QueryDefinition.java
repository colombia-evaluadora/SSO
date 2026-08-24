package com.co.eurekatic.query.catalog;

import com.co.eurekatic.common.query.ParamConstraint;
import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.Map;

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
 *
 * <p><b>V49</b> — {@code paramTypes} carries the author-declared
 * JDBC/PG type per caller-controlled placeholder. Empty/null means
 * "legacy row" — QueryService falls back to Spring's auto-derivation.
 * See {@code com.co.eurekatic.common.query.ParamBinder}.
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

        /** V33 — verbo HTTP de la fila: GET, POST o PUT. Null = POST. */

        @JsonProperty("httpMethod") String httpMethod,

        /**
         * V49 — {@code {"PARAM.NOMBRE":"TEXT", "BODY.IDS":"BIGINT[]", ...}}.
         * Nullable for back-compat with pre-V49 servers; treated as
         * empty map by {@code ParamBinder} (legacy auto-derive path).
         */
        @JsonProperty("paramTypes") Map<String, String> paramTypes,

        /**
         * V70 — restricciones de formato opcionales por placeholder,
         * adicionales a lo que declara {@code paramTypes}. Nullable
         * para back-compat con servidores pre-V70; tratado como mapa
         * vacío por {@code ParamConstraintValidator} ("sin
         * restricciones adicionales").
         */
        @JsonProperty("paramConstraints") Map<String, ParamConstraint> paramConstraints,

        /**
         * V110 — opt-in: when {@code true}, {@code QueryPathController}
         * may serve this row's {@code GET} result from Redis instead
         * of re-running the SQL. {@code false} (the default for
         * pre-V110 catalog servers, since the field is simply absent
         * from their JSON) preserves the always-hit-the-DB behavior.
         */
        @JsonProperty("cacheable") boolean cacheable,

        /**
         * V110 — staleness window in seconds when {@link #cacheable}
         * is {@code true}. Ignored otherwise.
         */
        @JsonProperty("cacheTtlSeconds") int cacheTtlSeconds
) {
    /**
     * V70/V110 back-compat (sin paramConstraints ni
     * cacheable/cacheTtlSeconds) — servidores de catálogo
     * pre-V70/pre-V110 no mandan esos campos; Jackson invoca este
     * constructor y cae a los defaults seguros (sin restricciones
     * adicionales, sin cachear).
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
             detail, action, style, null, "SELECT", null, "POST", null);
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
             detail, action, style, pathTemplate, executionMode, null, "POST", null);
    }

    /**
     * V31 back-compat (sin httpMethod). El verbo cae a POST,
     * que es lo que hacian todas las rutas antes de V33.
     */
    public QueryDefinition(Long idQuery, String uuid, String query,
                           String type, boolean publicEnd, boolean captcha,
                           String detail, String action, String style,
                           String pathTemplate, String executionMode,
                           String outParamNames) {
        this(idQuery, uuid, query, type, publicEnd, captcha,
             detail, action, style, pathTemplate, executionMode,
             outParamNames, "POST", null);
    }

    /**
     * V33 back-compat (sin paramTypes). Conserva la forma de 13
     * argumentos que los llamantes usaban antes de V49; el mapa de
     * tipos cae a {@code null}, que {@code ParamBinder} trata como
     * "sin tipos declarados" — el bind vuelve al comportamiento
     * anterior (Spring auto-derive del valor).
     */
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
