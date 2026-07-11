package com.co.eurekatic.query.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Per-instance datasource config driven exclusively by env
 * vars. Used in the <b>scale-out</b> deployment model where
 * admin-ui (or compose / k8s) provisions one
 * query-service container per backing datasource.
 *
 * <p>All knobs are env-only (no YAML fallback) so the
 * container is genuinely stateless — every config knob
 * comes from {@code -e} flags set by the provisioner. The
 * image is identical regardless of which dialect the
 * instance serves.
 *
 * <p><b>Mapping to env vars</b> (relaxes to standard
 * Spring Boot env → property):
 * <ul>
 *   <li>{@code QUERY_DS_DIALECT} → {@code dialect}
 *       (required; one of {@code postgres}, {@code oracle},
 *       {@code sqlserver})</li>
 *   <li>{@code QUERY_DS_URL} → {@code url} (required,
 *       full JDBC URL)</li>
 *   <li>{@code QUERY_DS_USERNAME} → {@code username}</li>
 *   <li>{@code QUERY_DS_PASSWORD} → {@code password}</li>
 *   <li>{@code QUERY_DS_DRIVER} → {@code driver-class-name}
 *       (optional — defaults per dialect)</li>
 *   <li>{@code QUERY_DS_POOL_SIZE} → {@code maximum-pool-size}
 *       (default 10)</li>
 *   <li>{@code QUERY_INSTANCE_NAME} → {@code instance-name}
 *       (optional — used as the Eureka service-id suffix and
 *       as the {@code spring.application.name} override.
 *       Defaults to the dialect name when blank.)</li>
 * </ul>
 */
@ConfigurationProperties(prefix = "query.ds")
public class InstanceProps {

    /** Dialect key — {@code postgres}, {@code oracle}, {@code sqlserver}. */
    private String dialect;
    private String url;
    private String username;
    private String password;
    private String driverClassName;
    private int maximumPoolSize = 10;
    /**
     * Optional. Used in two places:
     * <ul>
     *   <li>Spring application name (and therefore the
     *       Eureka {@code serviceId}) — defaults to
     *       {@code query-service-<dialect>} when blank.</li>
     *   <li>The {@code /actuator/info} bean for ops
     *       debugging.</li>
     * </ul>
     */
    private String instanceName;

    public String getDialect() { return dialect; }
    public void setDialect(String dialect) { this.dialect = dialect; }
    public String getUrl() { return url; }
    public void setUrl(String url) { this.url = url; }
    public String getUsername() { return username; }
    public void setUsername(String username) { this.username = username; }
    public String getPassword() { return password; }
    public void setPassword(String password) { this.password = password; }
    public String getDriverClassName() { return driverClassName; }
    public void setDriverClassName(String driverClassName) { this.driverClassName = driverClassName; }
    public int getMaximumPoolSize() { return maximumPoolSize; }
    public void setMaximumPoolSize(int maximumPoolSize) { this.maximumPoolSize = maximumPoolSize; }
    public String getInstanceName() { return instanceName; }
    public void setInstanceName(String instanceName) { this.instanceName = instanceName; }
}