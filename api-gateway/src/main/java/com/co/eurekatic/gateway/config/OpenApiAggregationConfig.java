package com.co.eurekatic.gateway.config;

import com.co.eurekatic.gateway.openapi.ServiceGatewayMapping;
import com.co.eurekatic.gateway.openapi.Source;
import com.github.benmanes.caffeine.cache.Cache;
import com.github.benmanes.caffeine.cache.Caffeine;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.context.properties.bind.Bindable;
import org.springframework.boot.context.properties.bind.Binder;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.Environment;
import org.springframework.http.HttpHeaders;
import org.springframework.web.reactive.function.client.WebClient;

import java.time.Duration;
import java.util.Collections;
import java.util.List;
import java.util.Map;

/**
 * Wiring for {@link com.co.eurekatic.gateway.openapi.OpenApiAggregatorService}:
 *
 * <ul>
 *   <li>{@link #loadBalancedWebClientBuilder()} — a plain
 *       {@code WebClient.Builder} (resolved URL per call from
 *       {@code ReactiveDiscoveryClient} inside the aggregator) for
 *       fetching each downstream service's spec.</li>
 *   <li>{@link #mergedDocCache()} — Caffeine cache so the merged
 *       doc is built at most once per TTL, not on every request.</li>
 *   <li>{@link #serviceGatewayMappings()} — translates the
 *       {@code springdoc.aggregator.services} YAML list into
 *       {@link ServiceGatewayMapping} records.</li>
 * </ul>
 */
@Configuration
@EnableConfigurationProperties
public class OpenApiAggregationConfig {

    /**
     * Plain {@link WebClient.Builder} — the aggregator resolves the
     * concrete {@code http://host:port} via
     * {@code ReactiveDiscoveryClient.getInstances(serviceId).get(0)}
     * and sets it as the {@code baseUrl} per call. We don't use
     * Spring's {@code @LoadBalanced} WebClient because we're inside
     * the gateway (the gateway itself is not load-balanced; only
     * downstream services are).
     */
    @Bean
    public WebClient.Builder loadBalancedWebClientBuilder() {
        return WebClient.builder();
    }

    @Bean
    public Cache<String, Map<String, Object>> mergedDocCache(
            @Value("${springdoc.cache.ttl:60s}") Duration ttl) {
        return Caffeine.newBuilder()
                .expireAfterWrite(ttl)
                .maximumSize(16)
                .build();
    }

    /**
     * Translates the YAML config into typed records. The YAML shape is
     * deliberately flat (one map per service with snake-case keys);
     * we keep that surface stable because it's documented for ops.
     *
     * <p>Note: the previous version of this method used
     * {@code @Value("${springdoc.aggregator.services:}")} with a
     * {@code List<Map<String, Object>>} target type. {@code @Value}
     * is a {@code String}-oriented binder; it can split comma lists
     * but cannot decode nested YAML structures, so the application
     * context failed to start with
     * "Cannot convert value of type 'java.lang.String' to required
     * type 'java.util.List' / 'java.util.Map'". Spring Boot's
     * {@link Binder} is the right tool for complex binding —
     * it's the same API the {@code @ConfigurationProperties}
     * machinery uses internally. We bind to
     * {@code Bindable.listOfMap(String, Object)} which matches the
     * YAML's {@code List<Map<String,Object>>} shape.
     */
    @Bean
    public List<ServiceGatewayMapping> serviceGatewayMappings(Environment env) {
        List<Map<String, Object>> raw = Binder.get(env)
                .bind("springdoc.aggregator.services",
                        Bindable.listOfMap(String.class, Object.class))
                .orElse(Collections.emptyList());
        if (raw.isEmpty()) {
            return Collections.emptyList();
        }
        return raw.stream()
                .map(OpenApiAggregationConfig::toMapping)
                .toList();
    }

    @SuppressWarnings("unchecked")
    private static ServiceGatewayMapping toMapping(Map<String, Object> row) {
        Object sourceObj = row.get("source");
        Source source = sourceObj == null
                ? Source.SPRINGDOC
                : Source.valueOf(String.valueOf(sourceObj).trim().toUpperCase());
        List<String> paths = (List<String>) row.getOrDefault("gateway-paths", List.of());
        // For catalog-sourced services the operator specifies a single
        // "/path-prefix/**" that rows from the catalog are joined onto.
        // For springdoc services, the operator specifies every path that
        // the gateway exposes for that service.
        return new ServiceGatewayMapping(
                (String) row.get("service-id"),
                source,
                paths,
                (String) row.getOrDefault("tag-prefix", (String) row.get("service-id")),
                (String) row.getOrDefault("description", ""));
    }

    /**
     * Convenience bean: a header name constant used by the
     * aggregator to authenticate against sso-admin's
     * {@code /internal/openapi/catalog} endpoint. Exposed so
     * tests can reference the same constant.
     */
    @Bean
    public String internalTokenHeaderName() {
        return HttpHeaders.AUTHORIZATION; // sso-admin's InternalTokenFilter reads X-Internal-Token OR Authorization
    }
}
