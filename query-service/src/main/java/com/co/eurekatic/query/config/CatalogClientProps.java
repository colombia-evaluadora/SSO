package com.co.eurekatic.query.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;

/**
 * Configuration for the {@code CatalogClient} — the
 * RestClient that hits sso-admin's {@code /getQuery} and
 * {@code /getWrite} endpoints.
 *
 * <p>Bound from {@code query.catalog.*}.
 *
 * <p>Why the base URL is configurable per-environment and
 * not hard-coded to {@code http://sso-admin}: in dev we
 * point at the gateway-routed address
 * ({@code http://localhost:8080/sso-admin}); in prod we
 * point at the service's direct address through service
 * discovery. Hard-coding one would break the other.
 */
@ConfigurationProperties(prefix = "query.catalog")
public class CatalogClientProps {

    /**
     * Base URL of sso-admin's HTTP surface. No trailing
     * slash. Example:
     * {@code http://sso-admin:8080/sso-admin} in prod,
     * {@code http://localhost:8080/sso-admin} in dev.
     */
    private String baseUrl = "http://localhost:8080/sso-admin";

    /**
     * Read timeout for a catalog call. Kept short because
     * the catalog round-trip is on the hot path of every
     * request — a slow catalog call shouldn't tie up a
     * worker thread for long.
     */
    private Duration readTimeout = Duration.ofSeconds(3);

    /**
     * Connection-establish timeout.
     */
    private Duration connectTimeout = Duration.ofSeconds(2);

    public String getBaseUrl() { return baseUrl; }
    public void setBaseUrl(String baseUrl) { this.baseUrl = baseUrl; }
    public Duration getReadTimeout() { return readTimeout; }
    public void setReadTimeout(Duration readTimeout) { this.readTimeout = readTimeout; }
    public Duration getConnectTimeout() { return connectTimeout; }
    public void setConnectTimeout(Duration connectTimeout) { this.connectTimeout = connectTimeout; }
}