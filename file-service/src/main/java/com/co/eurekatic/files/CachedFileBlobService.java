package com.co.eurekatic.files;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.stereotype.Service;

import java.time.Duration;
import java.util.Optional;

/**
 * Redis-backed cache of small S3 blobs, keyed by S3 object key
 * ({@code clave} — see {@link DownloadController#extraerClave}).
 *
 * <p><b>Where this sits relative to authorization — read this before
 * calling {@link #get} or {@link #put} from anywhere new.</b>
 * {@link DownloadController} calls this ONLY from
 * {@code streamearArchivo}, which every caller reaches strictly
 * AFTER its own authorization check has already passed
 * ({@code FileAccessService#puedeVer} for a user-bearer JWT, the
 * constant-time internal-token comparison for the catalog, the
 * public-classification gate for {@code /files/public/**}). The
 * cache key is the S3 object key alone — no caller identity in it —
 * which is safe PRECISELY BECAUSE every caller that reaches this
 * point has already been individually cleared to see this exact
 * file. Putting a `@Cacheable` (or any cache lookup) directly on a
 * {@code @GetMapping} method here would be a real vulnerability: the
 * Spring Cache AOP proxy short-circuits the method body — including
 * the authorization check inside it — on a cache hit, so a second
 * caller who was never authorized would receive the first caller's
 * file. Keep the cache boundary below the authorization check, not
 * around it.
 *
 * <p>Content-addressed by S3 key rather than by {@code archivoId}:
 * two different {@code TARCHIVO} rows never share a key, and a row
 * whose {@code urls3} changes (re-upload under a new key) simply
 * misses the old cache entry instead of serving stale bytes under a
 * key that still resolves.
 *
 * <p>Size-gated by {@link FileCacheProperties#getMaxCacheableBytes()}
 * — see that class and {@code application.yml} for why. Fails open
 * on every Redis error: a cache miss (real or simulated by an
 * exception) just means {@link DownloadController} falls through to
 * its normal S3 streaming path, exactly as if caching were disabled.
 */
@Service
public class CachedFileBlobService {

    private static final Logger log = LoggerFactory.getLogger(CachedFileBlobService.class);
    private static final String KEY_PREFIX = "files:blob:";

    private final RedisTemplate<String, byte[]> redis;
    private final FileCacheProperties props;

    public CachedFileBlobService(RedisTemplate<String, byte[]> redis, FileCacheProperties props) {
        this.redis = redis;
        this.props = props;
    }

    public Optional<byte[]> get(String clave) {
        if (!props.isEnabled()) {
            return Optional.empty();
        }
        try {
            return Optional.ofNullable(redis.opsForValue().get(KEY_PREFIX + clave));
        } catch (Exception e) {
            log.warn("file-blob cache read failed for clave={} (falling through to S3): {}",
                    clave, e.getMessage());
            return Optional.empty();
        }
    }

    /**
     * Caches {@code bytes} under {@code clave} unless caching is
     * disabled or the payload exceeds
     * {@link FileCacheProperties#getMaxCacheableBytes()} — the
     * caller (see {@link DownloadController#streamearArchivo}) only
     * ever invokes this after it has already decided the object is
     * small enough by its {@code Content-Length}, so the size check
     * here is a second, cheap confirmation rather than the primary
     * gate.
     */
    public void put(String clave, byte[] bytes) {
        if (!props.isEnabled() || bytes.length > props.getMaxCacheableBytes()) {
            return;
        }
        try {
            redis.opsForValue().set(KEY_PREFIX + clave, bytes, Duration.ofSeconds(props.getTtlSeconds()));
        } catch (Exception e) {
            log.warn("file-blob cache write failed for clave={} (bytes NOT cached): {}",
                    clave, e.getMessage());
        }
    }
}
