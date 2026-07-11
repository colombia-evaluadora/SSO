package com.co.eurekatic.query.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.NestedConfigurationProperty;

import java.util.HashMap;
import java.util.Map;

/**
 * Externalized datasource configuration. Bound from
 * {@code application.yml} under {@code query.datasources}.
 *
 * <p>Two deployment shapes are supported from the same props
 * class, and they're orthogonal — pick one or the other per
 * deployment:
 *
 * <ol>
 *   <li><b>Single-instance, multi-dialect (dev / small
 *       prod).</b> The YAML/env defines
 *       {@code query.datasources.entries.<dialect>.*} for
 *       one or more dialects. The single query-service
 *       process serves all of them; the
 *       {@code JdbcTemplateRegistry} routes requests by
 *       the catalog row's {@code TYPE} column.</li>
 *
 *   <li><b>Per-dialect instances (prod scale-out, the
 *       model admin-ui drives).</b> The admin creates a new
 *       {@code microservice} of kind QUERY for every
 *       backing datasource it needs (one for Oracle, one
 *       for the analytics Postgres, etc.). Each container
 *       is a fresh copy of this image with env vars
 *       {@code QUERY_DS_DIALECT=oracle},
 *       {@code QUERY_DS_URL=jdbc:oracle:thin:...},
 *       {@code QUERY_DS_USERNAME=...},
 *       {@code QUERY_DS_PASSWORD=...}. The image boots
 *       with one named pool and registers with Eureka
 *       under {@code query-service-<dialect>} (the
 *       auto-generated service id is the
 *       {@code spring.application.name} +
 *       {@code QUERY_INSTANCE_NAME} suffix).</li>
 * </ol>
 *
 * <p>When {@code QUERY_DS_DIALECT} is set, the
 * single-instance binding is ignored and the env-var
 * config wins. This keeps the dev path (one YAML) and the
 * scale-out path (env vars) from colliding on boot.
 *
 * <p><b>Constructor binding:</b> the
 * {@code Map<String, Entry>} is bound via the
 * {@link #DataSourceProps(Map)} constructor so the
 * property path {@code query.datasources.entries.<key>.*}
 * flows directly into the map keys. No field-name
 * guessing required.
 */
@ConfigurationProperties(prefix = "query.datasources")
public class DataSourceProps {

    /**
     * Dialect entries keyed by {@code "postgres"},
     * {@code "oracle"}, {@code "sqlserver"}.
     */
    private final Map<String, Entry> entries;

    public DataSourceProps(Map<String, Entry> entries) {
        this.entries = entries != null ? entries : new HashMap<>();
    }

    public Map<String, Entry> getEntries() {
        return entries;
    }

    /**
     * One dialect's connection settings + the names of
     * queries whose catalog row targets this DB.
     */
    public static class Entry {
        /** Master switch. {@code false} skips bean creation. */
        private boolean enabled = true;
        /** JDBC URL. */
        private String url;
        /** Driver class — defaults to one matching the dialect name. */
        private String driverClassName;
        private String username;
        private String password;
        /** Hikari pool size. */
        private int maximumPoolSize = 10;

        @NestedConfigurationProperty
        private HikariProps hikari = new HikariProps();

        public boolean isEnabled() { return enabled; }
        public void setEnabled(boolean enabled) { this.enabled = enabled; }
        public String getUrl() { return url; }
        public void setUrl(String url) { this.url = url; }
        public String getDriverClassName() { return driverClassName; }
        public void setDriverClassName(String driverClassName) { this.driverClassName = driverClassName; }
        public String getUsername() { return username; }
        public void setUsername(String username) { this.username = username; }
        public String getPassword() { return password; }
        public void setPassword(String password) { this.password = password; }
        public int getMaximumPoolSize() { return maximumPoolSize; }
        public void setMaximumPoolSize(int maximumPoolSize) { this.maximumPoolSize = maximumPoolSize; }
        public HikariProps getHikari() { return hikari; }
        public void setHikari(HikariProps hikari) { this.hikari = hikari; }
    }

    /**
     * Hikari tunables exposed via
     * {@code query.datasources.<name>.hikari.*}. Kept
     * separate from {@link Entry} so {@code @NestedConfigurationProperty}
     * works (records don't nest cleanly with relaxed binding).
     */
    public static class HikariProps {
        private long connectionTimeout = 30_000;
        private long idleTimeout = 600_000;
        private long maxLifetime = 1_800_000;
        private int minimumIdle = 2;

        public long getConnectionTimeout() { return connectionTimeout; }
        public void setConnectionTimeout(long connectionTimeout) { this.connectionTimeout = connectionTimeout; }
        public long getIdleTimeout() { return idleTimeout; }
        public void setIdleTimeout(long idleTimeout) { this.idleTimeout = idleTimeout; }
        public long getMaxLifetime() { return maxLifetime; }
        public void setMaxLifetime(long maxLifetime) { this.maxLifetime = maxLifetime; }
        public int getMinimumIdle() { return minimumIdle; }
        public void setMinimumIdle(int minimumIdle) { this.minimumIdle = minimumIdle; }
    }
}