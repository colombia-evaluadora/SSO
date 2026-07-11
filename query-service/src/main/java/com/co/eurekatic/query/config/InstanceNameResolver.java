package com.co.eurekatic.query.config;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.env.EnvironmentPostProcessor;
import org.springframework.core.Ordered;
import org.springframework.core.env.ConfigurableEnvironment;
import org.springframework.core.env.MapPropertySource;

import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

/**
 * Rewrites {@code spring.application.name} early in the
 * Boot lifecycle so the instance registers with Eureka
 * under a per-dialect service-id in scale-out deployments.
 *
 * <p>Logic:
 * <ul>
 *   <li>If {@code QUERY_INSTANCE_NAME} is set, use it
 *       <i>prefixed</i> with {@code query-service-} when it
 *       doesn't already start with that prefix. The
 *       provisioner passes just the suffix
 *       (e.g. {@code smoke-26182}) so the canonical service
 *       id becomes {@code query-service-smoke-26182}.</li>
 *   <li>Else if {@code QUERY_DS_DIALECT} is set, derive
 *       {@code query-service-<dialect>}.</li>
 *   <li>Else leave the YAML value untouched (single-instance
 *       / dev mode).</li>
 * </ul>
 *
 * <p>Why an {@link EnvironmentPostProcessor} instead of a
 * regular bean: the application name has to be set BEFORE
 * Spring Cloud's Eureka client builds its registration
 * payload (which reads {@code spring.application.name}
 * during context refresh). A regular
 * {@code @Configuration} bean runs too late.
 *
 * <p><b>Why HIGHEST_PRECEDENCE order:</b> this needs to run
 * before the {@code ConfigFileApplicationListener} so the
 * YAML-derived name (if any) gets overwritten by the env
 * var. Otherwise the YAML wins and every container ends up
 * as {@code query-service} regardless of the dialect it
 * serves.
 *
 * <p><b>Boot 4 registration:</b> this processor is wired
 * via {@code META-INF/spring/org.springframework.boot.env.
 * EnvironmentPostProcessor.imports}. The legacy
 * {@code spring.factories} entry of the same key is a
 * no-op in Boot 4 — Boot 4 only honors the {@code .imports}
 * file for {@code EnvironmentPostProcessor}.
 */
public class InstanceNameResolver implements EnvironmentPostProcessor, Ordered {

    private static final String SERVICE_PREFIX = "query-service-";

    @Override
    public void postProcessEnvironment(ConfigurableEnvironment env,
                                       SpringApplication application) {
        String explicitName = env.getProperty("query.instance.name");
        String dialect = env.getProperty("query.ds.dialect");
        String resolved;
        if (explicitName != null && !explicitName.isBlank()) {
            // The provisioner passes just the suffix (e.g.
            // "smoke-26182"). Prefix it with the canonical
            // service-id scheme so Eureka registers
            // `query-service-smoke-26182` and the gateway
            // discovery locator creates a matching route.
            // Skip the prefix when the caller already
            // supplied it (allows operator override).
            resolved = explicitName.startsWith(SERVICE_PREFIX)
                    ? explicitName
                    : SERVICE_PREFIX + explicitName;
        } else if (dialect != null && !dialect.isBlank()) {
            resolved = SERVICE_PREFIX + dialect.toLowerCase(Locale.ROOT);
        } else {
            // No instance info → leave it alone. Static
            // mode keeps its YAML name.
            return;
        }

        Map<String, Object> overrides = new HashMap<>();
        overrides.put("spring.application.name", resolved);
        env.getPropertySources().addFirst(
                new MapPropertySource("query-instance-name", overrides));
        // Make sure the value is visible via @Value etc.
        // (addFirst already gives it highest precedence.)
    }

    @Override
    public int getOrder() {
        // Run before ConfigFileApplicationListener (which
        // is HIGHEST_PRECEDENCE + 10) so we can win over
        // the YAML value if needed.
        return Ordered.HIGHEST_PRECEDENCE;
    }
}