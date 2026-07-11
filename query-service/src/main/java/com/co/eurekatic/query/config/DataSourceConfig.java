package com.co.eurekatic.query.config;

import com.zaxxer.hikari.HikariDataSource;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.jdbc.DataSourceBuilder;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import javax.sql.DataSource;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

/**
 * Builds {@link HikariDataSource}s for the dialects this
 * process is configured to serve, plus a
 * {@link NamedParameterJdbcTemplate} per dialect.
 *
 * <h2>Two boot modes</h2>
 *
 * <p><b>Instance mode</b> ({@link InstanceProps} bound and
 * {@code QUERY_DS_DIALECT} set): the container serves ONE
 * dialect, configured entirely via env vars. This is the
 * scale-out shape admin-ui drives — every backing datasource
 * gets its own container with its own Eureka service-id.
 *
 * <p><b>Static mode</b> ({@link DataSourceProps} bound via
 * {@code application.yml}): the container serves whatever
 * dialects are listed under
 * {@code query.datasources.entries.<name>.*}. Dev and small
 * prod use this.
 *
 * <p>{@code DataSourceAutoConfiguration} and
 * {@code JdbcTemplateAutoConfiguration} are excluded in
 * {@code application.yml}. If we let Boot's autoconfig run
 * it would create a phantom primary DataSource (H2 in test,
 * an unreachable URL in prod) that wins autowire races and
 * shadows our named pools.
 *
 * <p>When both modes are configured (e.g. the YAML has
 * Postgres AND {@code QUERY_DS_DIALECT=oracle} is set),
 * instance mode wins. The reasoning: env vars come from
 * the provisioner and are explicit per container; the YAML
 * is the dev-template fallback. A container should never
 * silently serve extra dialects the operator didn't ask
 * for.
 */
@Configuration
@EnableConfigurationProperties({ DataSourceProps.class, InstanceProps.class })
public class DataSourceConfig {

    private static final Logger log = LoggerFactory.getLogger(DataSourceConfig.class);

    /**
     * Default driver per dialect key — overridable via
     * {@code query.datasources.<name>.driver-class-name}
     * or {@code QUERY_DS_DRIVER}.
     */
    private static final Map<String, String> DEFAULT_DRIVERS = Map.of(
            "postgres", "org.postgresql.Driver",
            "oracle", "oracle.jdbc.OracleDriver",
            "sqlserver", "com.microsoft.sqlserver.jdbc.SQLServerDriver"
    );

    /**
     * All enabled datasources keyed by dialect name. Useful
     * for the {@code Actuator} health endpoint (one health
     * indicator per pool).
     */
    @Bean(name = "queryDataSources")
    public Map<String, DataSource> dataSources(DataSourceProps multi,
                                               InstanceProps single) {
        Map<String, DataSource> sources = new LinkedHashMap<>();

        if (single != null && single.getDialect() != null
                && !single.getDialect().isBlank()) {
            // INSTANCE MODE — one dialect, env-driven.
            String dialect = single.getDialect().toLowerCase(Locale.ROOT);
            sources.put(dialect, buildInstance(dialect, single));
            log.info("query-service in INSTANCE mode — serving only dialect '{}'",
                    dialect);
        } else if (multi != null && !multi.getEntries().isEmpty()) {
            // STATIC MODE — dev / small prod, YAML-driven.
            multi.getEntries().forEach((name, entry) -> {
                if (!entry.isEnabled()) {
                    log.info("Datasource '{}' is disabled — skipping bean", name);
                    return;
                }
                sources.put(name, buildEntry(name, entry));
                log.info("Datasource '{}' ready (static): pool={}, max={}, url={}",
                        name, "query-" + name, entry.getMaximumPoolSize(),
                        redact(entry.getUrl()));
            });
            log.info("query-service in STATIC mode — serving dialects: {}",
                    sources.keySet());
        } else {
            log.warn("No datasources configured. Set query.datasources.entries.<dialect>.* "
                    + "(static mode) or QUERY_DS_DIALECT + QUERY_DS_URL "
                    + "(instance mode).");
        }
        return sources;
    }

    /**
     * One {@link NamedParameterJdbcTemplate} per dialect.
     * Named parameter binding is preferred over positional
     * because the catalog query strings use {@code :param}
     * placeholders and admin authors expect that semantics.
     */
    @Bean(name = "queryJdbcTemplates")
    public Map<String, NamedParameterJdbcTemplate> jdbcTemplates(
            @org.springframework.beans.factory.annotation.Qualifier("queryDataSources")
                    Map<String, DataSource> dataSources) {
        Map<String, NamedParameterJdbcTemplate> templates = new HashMap<>();
        dataSources.forEach((name, ds) ->
                templates.put(name, new NamedParameterJdbcTemplate(ds)));
        return templates;
    }

    private DataSource buildEntry(String name, DataSourceProps.Entry entry) {
        String driver = entry.getDriverClassName() != null
                ? entry.getDriverClassName()
                : DEFAULT_DRIVERS.get(name);
        requireDriver(name, driver);
        HikariDataSource ds = DataSourceBuilder.create()
                .type(HikariDataSource.class)
                .driverClassName(driver)
                .url(entry.getUrl())
                .username(entry.getUsername())
                .password(entry.getPassword())
                .build();
        ds.setPoolName("query-" + name);
        ds.setMaximumPoolSize(entry.getMaximumPoolSize());
        ds.setConnectionTimeout(entry.getHikari().getConnectionTimeout());
        ds.setIdleTimeout(entry.getHikari().getIdleTimeout());
        ds.setMaxLifetime(entry.getHikari().getMaxLifetime());
        ds.setMinimumIdle(entry.getHikari().getMinimumIdle());
        return ds;
    }

    private DataSource buildInstance(String dialect, InstanceProps p) {
        String driver = p.getDriverClassName() != null
                ? p.getDriverClassName()
                : DEFAULT_DRIVERS.get(dialect);
        requireDriver(dialect, driver);
        if (p.getUrl() == null || p.getUrl().isBlank()) {
            throw new IllegalStateException(
                    "QUERY_DS_URL is required when QUERY_DS_DIALECT is set");
        }
        HikariDataSource ds = DataSourceBuilder.create()
                .type(HikariDataSource.class)
                .driverClassName(driver)
                .url(p.getUrl())
                .username(p.getUsername())
                .password(p.getPassword())
                .build();
        String instanceName = p.getInstanceName() != null
                && !p.getInstanceName().isBlank()
                ? p.getInstanceName()
                : dialect;
        ds.setPoolName("query-" + instanceName);
        ds.setMaximumPoolSize(p.getMaximumPoolSize());
        log.info("Datasource '{}' ready (instance): pool={}, max={}, url={}",
                dialect, ds.getPoolName(), p.getMaximumPoolSize(),
                redact(p.getUrl()));
        return ds;
    }

    private static void requireDriver(String name, String driver) {
        if (driver == null) {
            throw new IllegalStateException(
                    "Datasource '" + name + "' has no driver-class-name and no default. "
                            + "Known defaults: " + DEFAULT_DRIVERS.keySet());
        }
    }

    private static String redact(String url) {
        // Strip credentials if embedded in the JDBC URL
        // (Oracle URLs sometimes carry them).
        int q = url.indexOf('?');
        return q < 0 ? url : url.substring(0, q) + "?...";
    }
}