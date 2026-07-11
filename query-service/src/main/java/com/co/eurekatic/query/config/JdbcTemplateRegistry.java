package com.co.eurekatic.query.config;

import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ResponseStatusException;

import java.util.Map;

import static org.springframework.http.HttpStatus.BAD_GATEWAY;
import static org.springframework.http.HttpStatus.NOT_FOUND;

/**
 * Looks up a {@link NamedParameterJdbcTemplate} by dialect
 * key ({@code "postgres"}, {@code "oracle"},
 * {@code "sqlserver"}).
 *
 * <p>The lookup is keyed off the {@code TYPE} column in the
 * catalog query row. We deliberately do NOT accept a
 * dialect name from the request — only the catalog can tell
 * us which DB a given query targets. This keeps
 * "post to /query?uuid=foo&db=postgres" from being a thing.
 *
 * <p>If the resolved dialect is not configured (e.g. dev
 * running only Postgres but a query is catalogued as
 * Oracle), we return 502 — the catalog gave us a query we
 * cannot run, which is an operator misconfiguration, not a
 * client error. A 404 would suggest the query does not
 * exist, which is misleading.
 */
@Component
public class JdbcTemplateRegistry {

    private final Map<String, NamedParameterJdbcTemplate> templates;

    public JdbcTemplateRegistry(
            @org.springframework.beans.factory.annotation.Qualifier("queryJdbcTemplates")
                    Map<String, NamedParameterJdbcTemplate> templates) {
        this.templates = templates;
    }

    /**
     * Returns the {@link NamedParameterJdbcTemplate} for the
     * dialect named by {@code type}, or throws 502 if that
     * dialect is not configured.
     *
     * @param type the {@code TYPE} column from the catalog
     *             query row. Case-insensitive. {@code null}
     *             defaults to {@code postgres} for backward
     *             compatibility with catalog rows created
     *             before the TYPE column was mandatory.
     */
    public NamedParameterJdbcTemplate resolve(String type) {
        String key = (type == null || type.isBlank()) ? "postgres" : type.toLowerCase();
        NamedParameterJdbcTemplate t = templates.get(key);
        if (t == null) {
            throw new ResponseStatusException(BAD_GATEWAY,
                    "Dialect '" + key + "' is not configured in this deployment");
        }
        return t;
    }

    /**
     * Returns the set of configured dialect keys. Used by
     * the actuator endpoint to expose what this deployment
     * can serve.
     */
    public java.util.Set<String> configuredDialects() {
        return templates.keySet();
    }
}