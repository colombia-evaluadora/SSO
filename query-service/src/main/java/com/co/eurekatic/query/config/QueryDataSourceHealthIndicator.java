package com.co.eurekatic.query.config;

import org.springframework.boot.health.contributor.Health;
import org.springframework.boot.health.contributor.HealthIndicator;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Reports one {@code UP}/{@code DOWN} per configured dialect.
 *
 * <p>Boot's own {@code DataSourceHealthIndicator} does not cover these:
 * they are beans inside a qualified {@code Map} built by
 * {@link DataSourceConfig}, not the application's primary
 * {@code DataSource} — so until now a query-service whose Oracle pool was
 * unreachable still reported itself perfectly healthy, and the readiness
 * probe kept sending it traffic it could only answer with 502.
 *
 * <p>The check is {@code isValid()} on a pooled connection, which is what
 * HikariCP itself uses and is cheaper than issuing a query. A dialect that
 * fails takes the whole indicator DOWN: this service exists to reach those
 * databases, and one of them being gone means a real subset of the catalog
 * is unanswerable.
 *
 * <p>Detail is per dialect and deliberately says nothing beyond up/down and
 * the failure class — {@code management.endpoint.health.show-details} is
 * {@code never} in this deployment anyway, but a JDBC URL or a driver
 * message has no business in a health body even when details are on.
 */
@Component
public class QueryDataSourceHealthIndicator implements HealthIndicator {

    /** Seconds {@code Connection.isValid} may take before it counts as down. */
    private static final int VALIDATION_TIMEOUT_SECONDS = 2;

    private final Map<String, NamedParameterJdbcTemplate> templates;

    public QueryDataSourceHealthIndicator(
            @org.springframework.beans.factory.annotation.Qualifier("queryJdbcTemplates")
                    Map<String, NamedParameterJdbcTemplate> templates) {
        this.templates = templates;
    }

    @Override
    public Health health() {
        Map<String, String> byDialect = new LinkedHashMap<>();
        boolean allUp = true;

        for (Map.Entry<String, NamedParameterJdbcTemplate> e : templates.entrySet()) {
            boolean up = probe(e.getValue());
            byDialect.put(e.getKey(), up ? "UP" : "DOWN");
            allUp &= up;
        }

        Health.Builder health = allUp ? Health.up() : Health.down();
        byDialect.forEach(health::withDetail);
        return health.build();
    }

    private static boolean probe(NamedParameterJdbcTemplate jdbc) {
        try {
            Boolean valid = jdbc.getJdbcTemplate().execute(
                    (java.sql.Connection con) -> con.isValid(VALIDATION_TIMEOUT_SECONDS));
            return Boolean.TRUE.equals(valid);
        } catch (Exception e) {
            // Any failure to even obtain a connection is a DOWN. The
            // exception itself only goes to the log, never to the body.
            return false;
        }
    }
}
