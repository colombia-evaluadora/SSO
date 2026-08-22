package com.co.eurekatic.files;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Configuration for {@link CachedFileBlobService} — the Redis-backed
 * cache of small S3 blobs behind {@code GET
 * /files/download|view|public}. Bound from {@code files.cache.*}.
 *
 * <p>See {@code application.yml} for the tradeoff behind
 * {@link #maxCacheableBytes} — this service streams everything from
 * avatar-sized icons to multi-MB scanned PDFs through the same three
 * endpoints, and only the former belongs in Redis.
 */
@ConfigurationProperties(prefix = "files.cache")
public class FileCacheProperties {

    private boolean enabled = true;
    private long ttlSeconds = 300L;
    private long maxCacheableBytes = 2 * 1024 * 1024L;

    public boolean isEnabled() { return enabled; }
    public void setEnabled(boolean enabled) { this.enabled = enabled; }
    public long getTtlSeconds() { return ttlSeconds; }
    public void setTtlSeconds(long ttlSeconds) { this.ttlSeconds = ttlSeconds; }
    public long getMaxCacheableBytes() { return maxCacheableBytes; }
    public void setMaxCacheableBytes(long maxCacheableBytes) { this.maxCacheableBytes = maxCacheableBytes; }
}
