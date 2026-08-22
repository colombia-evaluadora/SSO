package com.co.eurekatic.query.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Configuration for query-service's Redis-backed
 * {@code @Cacheable} usage. Bound from {@code query.cache.*}.
 *
 * <p>Two independent concerns share this prefix:
 * <ul>
 *   <li>{@link #getMetadataTtlSeconds()} — TTL for the schema
 *       introspection caches ({@code "tables"} / {@code "columns"}
 *       cache names) backing {@code GET /tables} and
 *       {@code GET /columns}. These never depend on the caller,
 *       only on dialect + schema/table filter, so a single shared
 *       TTL is enough.</li>
 *   <li>{@link #isCatalogEnabled()} — master switch for the
 *       opt-in, per-catalog-row cache applied in
 *       {@code QueryPathController} to {@code GET} rows the
 *       catalog author marked {@code cacheable=true}. See
 *       {@code CatalogResultCacheService} for why this is opt-in
 *       rather than blanket: {@code GET /**} runs arbitrary
 *       catalog SQL with caller context baked into the bind
 *       params, so caching is only safe when the query author
 *       has actively decided their result is safe to reuse across
 *       identical (path+query+body+caller) requests for a bounded
 *       window.</li>
 * </ul>
 */
@ConfigurationProperties(prefix = "query.cache")
public class QueryCacheProperties {

    private long metadataTtlSeconds = 600L;
    private boolean catalogEnabled = true;

    public long getMetadataTtlSeconds() { return metadataTtlSeconds; }
    public void setMetadataTtlSeconds(long metadataTtlSeconds) { this.metadataTtlSeconds = metadataTtlSeconds; }
    public boolean isCatalogEnabled() { return catalogEnabled; }
    public void setCatalogEnabled(boolean catalogEnabled) { this.catalogEnabled = catalogEnabled; }
}
