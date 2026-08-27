package com.co.eurekatic.query.routing;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.query.config.QueryCacheProperties;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.redis.core.Cursor;
import org.springframework.data.redis.core.ScanOptions;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Service;

import java.security.MessageDigest;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.SortedMap;
import java.util.TreeMap;

/**
 * Redis-backed result cache for {@code GET} rows the catalog author
 * marked {@code cacheable=true} (V65) — see
 * {@code QueryPathController#dispatch}.
 *
 * <p><b>Why this bypasses the {@code @Cacheable}/{@code RedisCacheManager}
 * machinery</b> that {@code TablesService}/{@code ColumnsService}
 * use: every catalog row can declare its own {@code cacheTtlSeconds},
 * and Spring's Cache SPI only supports one TTL per cache NAME. This
 * service talks to Redis directly with {@code StringRedisTemplate}
 * and an explicit {@code Duration} per {@code SET} — same pattern as
 * auth-center's {@code RedisRefreshTokenStore}. See
 * {@code RedisCacheConfig}'s javadoc for the full rationale.
 *
 * <p><b>Cache-key safety — why the caller's identity is baked into
 * the key.</b> A {@code GET /**} row runs catalog SQL that can
 * reference {@code :CONTEXT.USER_ID} / {@code :CONTEXT.EMAIL} /
 * {@code :CONTEXT.ROLES} — the same request URL can legitimately
 * return different rows for different callers. Keying purely on
 * {@code (uuid, path, query params)} would let user B's request hit
 * a cache entry user A's request populated, silently leaking A's
 * data to B. {@link #keyFor} folds the caller's identity (userId if
 * authenticated, else the literal {@code "anon"} for a
 * {@code publicEnd} row) into the key so two different callers
 * NEVER share an entry.
 *
 * <p><b>V66 — write-triggered invalidation, scoped by resource.</b>
 * A per-row TTL bounds staleness, but a catalog author who wants
 * "always current" (not "current within N seconds") needs writes to
 * actively clear what they might have made stale. There is no
 * catalog metadata linking a write row to the exact GET rows it
 * affects, so this service approximates the relationship with the
 * one signal every path-based row already carries for free: the
 * FIRST static segment of its path template. {@code POST /menus},
 * {@code PATCH /menus/:ID}, and {@code PUT /menus/order} all resolve
 * to the resource tag {@code "menus"}; {@code GET /menus} and
 * {@code GET /menus/:ID} do too — so a write under {@code /menus/**}
 * invalidates exactly the cached GETs that also live under
 * {@code /menus/**}, and leaves {@code /roles/**}, {@code /grados/**},
 * etc. completely untouched. See {@link #resourceTag} for the
 * extraction rule and {@link #invalidateForResource} for the call
 * site.
 *
 * <p>This is an approximation, not a guarantee: two genuinely
 * unrelated rows that happen to share a first path segment (e.g. an
 * author who nests {@code /menus/icons} under the same prefix for a
 * completely different table) would over-invalidate each other. That
 * failure mode is still SAFE (an extra cache miss, never stale data)
 * — the opposite mistake (under-invalidating two rows that share
 * data but not a path prefix) is the one this design can't catch,
 * same limitation any path-convention-based cache tagging has
 * without an explicit catalog-authored mapping. {@link #invalidateAll()}
 * remains available as the deliberately-blunt fallback for the one
 * case where there's no path template to key off at all (a legacy
 * {@code /query}/{@code /service} row saved before V27, or any write
 * through {@link com.co.eurekatic.query.write.WriteService}, whose
 * catalog — {@code WriteDefinition} — has no path template concept).
 *
 * <p><b>Fail-open on every Redis error.</b> A cache read/write/
 * invalidate failure (connection reset, timeout, serialization bug)
 * must never turn into a 5xx for what is, underneath, a purely
 * additive optimization — the request falls through to the normal
 * DB path exactly as if {@code cacheable} were false. Every method
 * here swallows its own exceptions and logs at WARN.
 */
@Service
public class CatalogResultCacheService {

    private static final Logger log = LoggerFactory.getLogger(CatalogResultCacheService.class);
    private static final TypeReference<Map<String, Object>> RESULT_TYPE =
            new TypeReference<>() { };

    /** {@link #resourceTag} for a path with no meaningful first
     *  segment ({@code null}, blank, or bare {@code "/"}) — the
     *  legacy-row / no-path-template fallback bucket. Never matched
     *  by {@link #invalidateForResource}; only {@link #invalidateAll()}
     *  reaches entries filed under it. */
    private static final String UNKNOWN_RESOURCE = "_unknown";

    /**
     * Number of keys fetched per {@code SCAN} round-trip when
     * walking the keyspace for {@link #invalidateAll()} /
     * {@link #invalidateForResource}. {@code SCAN} (not {@code KEYS})
     * is deliberate: {@code KEYS} blocks the whole Redis instance for
     * the duration of the call, which would stall {@code sso:refresh:*}
     * and {@code sso:session:*} traffic from auth-center sharing the
     * same Redis. {@code SCAN} yields control back between batches —
     * the standard non-blocking way to walk a pattern in production
     * Redis.
     */
    private static final int SCAN_BATCH_SIZE = 200;

    private final StringRedisTemplate redis;
    private final ObjectMapper objectMapper;
    private final QueryCacheProperties props;

    /**
     * This container's {@code query.instance.name} (e.g.
     * {@code "eval-col"}), or {@code "global"} in static/single-
     * instance mode (no {@code QUERY_INSTANCE_NAME} env var — see
     * {@code QueryPathRegistry}'s constructor for the identical
     * pattern). Scopes every cache key so invalidation never wipes
     * another instance's entries — see class javadoc.
     */
    private final String scope;
    private final String keyPrefix;

    public CatalogResultCacheService(StringRedisTemplate redis, ObjectMapper objectMapper,
                                     QueryCacheProperties props,
                                     @Value("${query.instance.name:#{null}}") String instanceName) {
        this.redis = redis;
        this.objectMapper = objectMapper;
        this.props = props;
        this.scope = (instanceName == null || instanceName.isBlank()) ? "global" : instanceName;
        this.keyPrefix = "query:catalog-get:" + scope + ":";
    }

    /**
     * The resource tag a path groups under: the first static
     * (non-empty) segment, lowercased. Examples:
     * <pre>
     *   /menus                  → "menus"
     *   /menus/:ID               → "menus"
     *   /menus/:ID/eliminar      → "menus"
     *   /roles/:ROLEID/menus     → "roles"   (NOT "menus" — the
     *                                         resource being acted on
     *                                         is the role, not the
     *                                         menu; see class javadoc
     *                                         on why this is an
     *                                         approximation)
     *   /select                  → "select"
     *   /select/:CATEGORIA       → "select"
     * </pre>
     * Returns {@link #UNKNOWN_RESOURCE} for {@code null}/blank/bare
     * {@code "/"} — {@link #invalidateAll()} is the only thing that
     * reaches entries filed there.
     */
    static String resourceTag(String path) {
        if (path == null || path.isBlank()) {
            return UNKNOWN_RESOURCE;
        }
        String trimmed = path.startsWith("/") ? path.substring(1) : path;
        int slash = trimmed.indexOf('/');
        String first = slash < 0 ? trimmed : trimmed.substring(0, slash);
        return first.isBlank() ? UNKNOWN_RESOURCE : first.toLowerCase(Locale.ROOT);
    }

    /**
     * Cache key for a {@code GET} dispatch — see class javadoc for
     * why the caller's identity is part of it, and {@link #resourceTag}
     * for the leading {@code <resource>:} component that lets a write
     * invalidate just this resource's entries. Query params are
     * sorted before hashing so {@code ?a=1&b=2} and {@code ?b=2&a=1}
     * — the same request from the caller's point of view — share an
     * entry. {@code fullPath} already includes the resolved path
     * variables (it's the literal request path), so it doesn't need
     * separate treatment.
     *
     * <p>SHA-256 over the joined components rather than the raw
     * string: keeps the Redis key short and fixed-length regardless
     * of how large the query string or path gets, and sidesteps
     * worrying about characters that aren't safe in a Redis key.
     */
    public static String keyFor(String uuid, String fullPath,
                                Map<String, String> queryParams,
                                Authentication auth) {
        SortedMap<String, String> sortedParams = new TreeMap<>(queryParams == null ? Map.of() : queryParams);
        String caller = callerIdentity(auth);
        String raw = uuid + '|' + fullPath + '|' + sortedParams + '|' + caller;
        return resourceTag(fullPath) + ':' + sha256Hex(raw);
    }

    /**
     * The current request's caller identity for cache-key purposes.
     * Prefers {@code userId} (stable across email changes); falls
     * back to email when userId is absent (legacy tokens — see
     * {@link AuthPrincipal#userId()}); {@code "anon"} for a
     * {@code publicEnd} row invoked without a JWT at all. Reads off
     * {@link SecurityContextHolder} directly rather than accepting
     * the {@code Authentication} the controller already has, so a
     * mismatch between "who dispatch() authenticated against" and
     * "whose cache entry we key against" is structurally impossible.
     */
    private static String callerIdentity(Authentication auth) {
        if (auth != null && auth.getPrincipal() instanceof AuthPrincipal p) {
            if (p.userId() != null) {
                return "u:" + p.userId();
            }
            if (p.email() != null && !p.email().isBlank()) {
                return "e:" + p.email();
            }
        }
        return "anon";
    }

    private static String sha256Hex(String raw) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256")
                    .digest(raw.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder(digest.length * 2);
            for (byte b : digest) {
                sb.append(String.format("%02x", b));
            }
            return sb.toString();
        } catch (java.security.NoSuchAlgorithmException e) {
            // SHA-256 is guaranteed present on every JVM (JLS/JCA
            // mandatory algorithm) — this branch is unreachable in
            // practice. Rethrow unchecked rather than pollute every
            // caller's signature for a case that cannot happen.
            throw new IllegalStateException(e);
        }
    }

    public Optional<Map<String, Object>> get(String cacheKey) {
        if (!props.isCatalogEnabled()) {
            return Optional.empty();
        }
        try {
            String raw = redis.opsForValue().get(keyPrefix + cacheKey);
            if (raw == null) {
                return Optional.empty();
            }
            return Optional.of(objectMapper.readValue(raw, RESULT_TYPE));
        } catch (Exception e) {
            // Fail open — see class javadoc.
            log.warn("catalog-get cache read failed for key={} (falling through to DB): {}",
                    cacheKey, e.getMessage());
            return Optional.empty();
        }
    }

    public void put(String cacheKey, Map<String, Object> result, int ttlSeconds) {
        if (!props.isCatalogEnabled()) {
            return;
        }
        try {
            String json = objectMapper.writeValueAsString(result);
            redis.opsForValue().set(keyPrefix + cacheKey, json, Duration.ofSeconds(ttlSeconds));
        } catch (Exception e) {
            // Fail open — see class javadoc. The caller already has
            // a correct response to return; a cache-write failure
            // must not turn that into a 500.
            log.warn("catalog-get cache write failed for key={} (result NOT cached): {}",
                    cacheKey, e.getMessage());
        }
    }

    /**
     * V66 — call this after a successful write whose catalog row
     * carries a {@code pathTemplate} (path-dispatch {@code POST}/
     * {@code PUT}/{@code PATCH}, or a legacy {@code /query} row that
     * happens to have one). Only cache entries under the SAME
     * resource ({@link #resourceTag}) are removed — a write on
     * {@code /menus/**} never touches {@code /roles/**}'s cached
     * GETs. Falls back to {@link #invalidateAll()} when
     * {@code writePathTemplate} is {@code null}/blank: with no path
     * to derive a tag from, "invalidate everything in this instance"
     * is the only safe option.
     *
     * @return number of cache entries removed.
     */
    public long invalidateForResource(String writePathTemplate) {
        if (writePathTemplate == null || writePathTemplate.isBlank()) {
            return invalidateAll();
        }
        String tag = resourceTag(writePathTemplate);
        return deleteMatching(keyPrefix + tag + ":*", tag);
    }

    /**
     * The blunt, always-correct fallback: drop every cached GET this
     * instance holds, regardless of resource. See class javadoc for
     * when this is used instead of {@link #invalidateForResource}
     * (writes with no path template — the legacy {@code /write}
     * endpoint's {@code WriteDefinition} has no path-template
     * concept at all, so {@code WriteService} always calls this one
     * directly).
     *
     * @return number of cache entries removed.
     */
    public long invalidateAll() {
        return deleteMatching(keyPrefix + "*", "*");
    }

    /**
     * Shared {@code SCAN}-then-{@code DEL} walk behind both
     * invalidation entry points — the only difference between them
     * is the glob pattern.
     */
    private long deleteMatching(String pattern, String tagForLogging) {
        if (!props.isCatalogEnabled()) {
            return 0;
        }
        try {
            List<String> toDelete = new ArrayList<>();
            ScanOptions options = ScanOptions.scanOptions()
                    .match(pattern)
                    .count(SCAN_BATCH_SIZE)
                    .build();
            try (Cursor<String> cursor = redis.scan(options)) {
                while (cursor.hasNext()) {
                    toDelete.add(cursor.next());
                }
            }
            if (toDelete.isEmpty()) {
                return 0;
            }
            Long removed = redis.delete(toDelete);
            long count = removed == null ? 0 : removed;
            log.debug("catalog-get cache invalidated: {} entries removed (scope={}, resource={})",
                    count, scope, tagForLogging);
            return count;
        } catch (Exception e) {
            // Fail open — see class javadoc. A write already
            // committed to Postgres; failing to clear Redis just
            // means the OLD ttl-bounded staleness window applies
            // again instead of "always current" — degraded, not
            // broken.
            log.warn("catalog-get cache invalidation failed (scope={}, resource={}, entries may be stale until TTL): {}",
                    scope, tagForLogging, e.getMessage());
            return 0;
        }
    }
}
