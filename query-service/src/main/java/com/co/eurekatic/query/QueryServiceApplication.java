package com.co.eurekatic.query;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

/**
 * Query-service entry point.
 *
 * <p>Three roles:
 * <ol>
 *   <li>Read path: {@code /query}, {@code /service},
 *       {@code /serviceFit}, {@code /public/service} —
 *       resolve a uuid to a SQL definition via the
 *       sso-admin catalog, run it, return rows.</li>
 *   <li>Write path: {@code /write} — resolve a uuid to a
 *       write definition (table + columns + key columns),
 *       bind {@code :param} placeholders from the request
 *       body, execute an INSERT or UPDATE.</li>
 *   <li>Catalog consumer — every request starts with a
 *       round-trip to sso-admin's {@code /getQuery} or
 *       {@code /getWrite} so we never accept table or
 *       column names from the client.</li>
 * </ol>
 *
 * <p>The {@code DataSourceAutoConfiguration} (and friends)
 * are excluded because this service owns its own
 * multi-datasource setup ({@code DataSourceConfig}) keyed
 * off {@code query.datasources.*}. Letting Boot
 * autoconfig a "primary" datasource would conflict with
 * our {@code Map<String, DataSource>} and (worse) silently
 * pick up a default URL on startup.
 */
/**
 * Excluded by FQN because the auto-config classes themselves
 * are not part of the compile classpath of starter-jdbc /
 * starter-data-jpa (they're packaged in
 * {@code spring-boot-autoconfigure} which we don't depend
 * on directly). Using class literals here would fail to
 * compile; Spring resolves these by reflection at boot.
 */
@SpringBootApplication
@ConfigurationPropertiesScan(basePackages = "com.co.eurekatic.query.config")
public class QueryServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(QueryServiceApplication.class, args);
    }
}