package com.co.eurekatic.gateway.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.util.ArrayList;
import java.util.List;

/**
 * Typed binding for the {@code springdoc.aggregator.*} subtree of
 * {@code application.yml}.
 *
 * <p>Bound by {@link OpenApiAggregationConfig#aggregatorProperties()}.
 * Each entry under {@code springdoc.aggregator.services} is a
 * {@link Service} with the snake-case keys the operator
 * already documents in the YAML. Keeping this as a typed
 * class (instead of a {@code List<Map<String,Object>>}) lets
 * {@code @ConfigurationProperties} do the heavy lifting; the
 * bean method then just converts each {@link Service} to a
 * {@code ServiceGatewayMapping}.
 *
 * <p>The inner class is static so the metadata is registered
 * cleanly via {@code @ConfigurationProperties} (Spring
 * requires a static inner or top-level type for binding).
 */
@ConfigurationProperties(prefix = "springdoc.aggregator")
public class SpringdocAggregatorProperties {

    /** Optional URL of sso-admin's /internal/openapi/catalog. */
    private String catalogUrl;

    /** X-Internal-Token shared with sso-admin for the catalog call. */
    private String catalogInternalToken;

    /** Per-service OpenAPI aggregation config. */
    private List<Service> services = new ArrayList<>();

    public String getCatalogUrl() { return catalogUrl; }
    public void setCatalogUrl(String catalogUrl) { this.catalogUrl = catalogUrl; }

    public String getCatalogInternalToken() { return catalogInternalToken; }
    public void setCatalogInternalToken(String catalogInternalToken) {
        this.catalogInternalToken = catalogInternalToken;
    }

    public List<Service> getServices() { return services; }
    public void setServices(List<Service> services) { this.services = services; }

    /**
     * One row of {@code springdoc.aggregator.services[*]}.
     * Field names mirror the YAML keys; the conversion to
     * {@code ServiceGatewayMapping} happens in
     * {@link OpenApiAggregationConfig#serviceGatewayMappings}.
     */
    public static class Service {
        private String serviceId;
        /** "springdoc" (default) or "catalog". */
        private String source;
        /** Path suffixes the gateway exposes for this service. */
        private List<String> gatewayPaths = new ArrayList<>();
        private String tagPrefix;
        private String description;

        public String getServiceId() { return serviceId; }
        public void setServiceId(String serviceId) { this.serviceId = serviceId; }

        public String getSource() { return source; }
        public void setSource(String source) { this.source = source; }

        public List<String> getGatewayPaths() { return gatewayPaths; }
        public void setGatewayPaths(List<String> gatewayPaths) { this.gatewayPaths = gatewayPaths; }

        public String getTagPrefix() { return tagPrefix; }
        public void setTagPrefix(String tagPrefix) { this.tagPrefix = tagPrefix; }

        public String getDescription() { return description; }
        public void setDescription(String description) { this.description = description; }
    }
}
