package com.co.eurekatic.gateway.config;

import com.co.eurekatic.gateway.openapi.ServiceGatewayMapping;
import com.co.eurekatic.gateway.openapi.Source;
import com.github.benmanes.caffeine.cache.Cache;
import com.github.benmanes.caffeine.cache.Caffeine;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
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
 *   <li>{@link #aggregatorProperties()} — typed binding of
 *       {@code springdoc.aggregator.*} (catalog URL, internal
 *       token, services list).</li>
 *   <li>{@link #serviceGatewayMappings(SpringdocAggregatorProperties)}
 *       — translates the typed services list into
 *       {@link ServiceGatewayMapping} records.</li>
 * </ul>
 *
 * <p>Why @ConfigurationProperties instead of @Value for the
 * services list: the previous version used
 * {@code @Value("${springdoc.aggregator.services:}")} with a
 * {@code List<Map<String,Object>>} target type. @Value is a
 * String-oriented binder; it can split comma lists but cannot
 * decode nested YAML structures, so the application context
 * failed to start with "Cannot convert value of type
 * 'java.lang.String' to required type 'java.util.List' /
 * 'java.util.Map'". A typed
 * {@link SpringdocAggregatorProperties} class lets Spring
 * Boot's Binder do the YAML-to-POJO conversion cleanly. The
 * operator-facing YAML shape (snake-case keys, "services"
 * list under springdoc.aggregator) is preserved.
 */
@Configuration
@EnableConfigurationProperties(SpringdocAggregatorProperties.class)
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
     * Translates the typed services list (bound by
     * {@link SpringdocAggregatorProperties} via
     * {@code @EnableConfigurationProperties} on this class) into
     * the runtime records. Each YAML row under
     * {@code springdoc.aggregator.services} becomes one
     * {@link ServiceGatewayMapping}.
     */
    @Bean
    public List<ServiceGatewayMapping> serviceGatewayMappings(
            SpringdocAggregatorProperties props) {
        if (props.getServices() == null || props.getServices().isEmpty()) {
            return Collections.emptyList();
        }
        return props.getServices().stream()
                .map(OpenApiAggregationConfig::toMapping)
                .toList();
    }

    private static ServiceGatewayMapping toMapping(SpringdocAggregatorProperties.Service row) {
        Source source = row.getSource() == null || row.getSource().isBlank()
                ? Source.SPRINGDOC
                : Source.valueOf(row.getSource().trim().toUpperCase());
        List<String> paths = row.getGatewayPaths() == null
                ? List.of()
                : row.getGatewayPaths();
        // For catalog-sourced services the operator specifies a single
        // "/path-prefix/**" that rows from the catalog are joined onto.
        // For springdoc services, the operator specifies every path that
        // the gateway exposes for that service.
        String tagPrefix = row.getTagPrefix() != null && !row.getTagPrefix().isBlank()
                ? row.getTagPrefix()
                : row.getServiceId();
        return new ServiceGatewayMapping(
                row.getServiceId(),
                source,
                paths,
                tagPrefix,
                row.getDescription() == null ? "" : row.getDescription());
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
