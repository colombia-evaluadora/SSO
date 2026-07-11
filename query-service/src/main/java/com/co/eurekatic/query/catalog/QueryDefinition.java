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
        @JsonProperty("style") String style
) {}