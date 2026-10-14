package com.co.eurekatic.query.catalog;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.github.benmanes.caffeine.cache.Cache;
import com.github.benmanes.caffeine.cache.Caffeine;
import io.micrometer.core.instrument.MeterRegistry;
import io.micrometer.core.instrument.binder.cache.CaffeineCacheMetrics;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.security.core.Authentication;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.function.Supplier;

/**
 * Caché local de las definiciones del catálogo ({@code /getQuery},
 * {@code /getWrite}), para no hacer una llamada HTTP a sso-admin por petición.
 *
 * <p>sso-admin autoriza por el email del llamador (sus roles en BD), así que la
 * clave es {@code email|uuid} ({@code anon} sin autenticar), en un espacio
 * distinto para lecturas y escrituras. Solo se guardan respuestas correctas:
 * un 403/404 o un error del catálogo se propagan y no se cachean.
 *
 * <p>Un cambio de roles de un usuario tarda hasta el TTL
 * ({@code QUERY_CATALOG_CACHE_TTL_SECONDS}) en reflejarse. Un cambio del
 * catálogo vacía todo vía {@code POST /internal/path-registry/invalidate}
 * ({@link #invalidateAll()}).
 */
@Component
public class CatalogDefinitionCache {

    private final CatalogClient catalog;
    private final boolean enabled;
    private final Cache<String, QueryDefinition> queries;
    private final Cache<String, WriteDefinition> writes;

    public CatalogDefinitionCache(
            CatalogClient catalog,
            MeterRegistry meters,
            @Value("${query.catalog.cache.enabled:true}") boolean enabled,
            @Value("${query.catalog.cache.ttl-seconds:60}") long ttlSeconds,
            @Value("${query.catalog.cache.max-size:50000}") long maxSize) {
        this.catalog = catalog;
        this.enabled = enabled;
        this.queries = build(ttlSeconds, maxSize);
        this.writes = build(ttlSeconds, maxSize);
        // Sin tags de usuario: solo el nombre de la caché.
        CaffeineCacheMetrics.monitor(meters, queries, "catalog.definition.query");
        CaffeineCacheMetrics.monitor(meters, writes, "catalog.definition.write");
    }

    private static <V> Cache<String, V> build(long ttlSeconds, long maxSize) {
        return Caffeine.newBuilder()
                .expireAfterWrite(Duration.ofSeconds(ttlSeconds))
                .maximumSize(maxSize)
                .recordStats()
                .build();
    }

    /**
     * Definición de lectura para {@code uuid}; {@code auth} puede ser null
     * (anónimo, solo en {@code /public/service}): sso-admin no acepta
     * {@code /getQuery} sin JWT, así que el anónimo va por el endpoint
     * interno que solo devuelve consultas públicas.
     */
    public QueryDefinition query(Authentication auth, String bearer, String uuid) {
        if (auth == null) {
            return resolve(queries, auth, uuid, () -> catalog.fetchPublicQuery(uuid));
        }
        return resolve(queries, auth, uuid, () -> catalog.fetchQuery(bearer, uuid));
    }

    /** Definición de escritura para {@code uuid}. */
    public WriteDefinition write(Authentication auth, String bearer, String uuid) {
        return resolve(writes, auth, uuid, () -> catalog.fetchWrite(bearer, uuid));
    }

    /** Vacía ambas cachés (cambio del catálogo). */
    public void invalidateAll() {
        queries.invalidateAll();
        writes.invalidateAll();
    }

    private <V> V resolve(Cache<String, V> cache, Authentication auth, String uuid,
                          Supplier<V> loader) {
        if (!enabled) {
            return loader.get();
        }
        String key = identity(auth) + "|" + uuid;
        V hit = cache.getIfPresent(key);
        if (hit != null) {
            return hit;
        }
        V value = loader.get();
        if (value != null) {
            cache.put(key, value);
        }
        return value;
    }

    private static String identity(Authentication auth) {
        if (auth != null && auth.getPrincipal() instanceof AuthPrincipal p
                && p.email() != null && !p.email().isBlank()) {
            return p.email();
        }
        return "anon";
    }
}
