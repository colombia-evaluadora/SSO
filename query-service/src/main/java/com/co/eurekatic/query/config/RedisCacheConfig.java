package com.co.eurekatic.query.config;

import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.cache.annotation.EnableCaching;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.cache.RedisCacheConfiguration;
import org.springframework.data.redis.cache.RedisCacheManager;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.serializer.GenericJackson2JsonRedisSerializer;
import org.springframework.data.redis.serializer.RedisSerializationContext;
import org.springframework.data.redis.serializer.StringRedisSerializer;

import java.time.Duration;
import java.util.Map;

/**
 * Redis-backed {@link org.springframework.cache.CacheManager} for
 * query-service — same pattern as auth-center's
 * {@code RedisConfig}/sso-admin's {@code CacheConfig}: one shared
 * {@code sso-redis} instance, cache names as the only namespacing.
 *
 * <p>Cache names registered here:
 * <ul>
 *   <li>{@code "tables"} / {@code "columns"} — schema introspection,
 *       see {@link com.co.eurekatic.query.read.TablesService} /
 *       {@link com.co.eurekatic.query.read.ColumnsService}. TTL
 *       from {@link QueryCacheProperties#getMetadataTtlSeconds()}.</li>
 * </ul>
 *
 * <p>The opt-in per-catalog-row cache ({@code GET} dispatch, see
 * {@code CatalogResultCacheService}) deliberately does NOT go
 * through this {@code CacheManager}. Every catalog row can declare
 * its own {@code cacheTtlSeconds}, and the Spring Cache SPI's
 * {@code RedisCacheManager} only supports one TTL per cache NAME,
 * not per entry — there is no {@code @Cacheable(ttl = ...)}. Rather
 * than fake per-row TTLs with N cache names (one per distinct TTL
 * value catalog authors might type in), {@code CatalogResultCacheService}
 * talks to Redis directly via {@code StringRedisTemplate} and calls
 * {@code opsForValue().set(key, json, Duration.ofSeconds(ttl))} —
 * same reasoning, and same pattern, as auth-center's
 * {@code RedisRefreshTokenStore} bypassing {@code @Cacheable} for
 * its own per-token TTL.
 *
 * <p>Every entry here is plain {@code GenericJackson2JsonRedisSerializer}
 * JSON — nothing cached here is a JPA entity or otherwise
 * polymorphism-sensitive at the root (see auth-center's
 * {@code RedisConfig} javadoc for the one case where that DOES
 * matter), so there is no need for a per-cache typed serializer.
 */
@Configuration
@EnableCaching
@EnableConfigurationProperties(QueryCacheProperties.class)
public class RedisCacheConfig {

    @Bean
    public RedisCacheManager cacheManager(RedisConnectionFactory connectionFactory,
                                          QueryCacheProperties props) {
        RedisCacheConfiguration defaults = RedisCacheConfiguration.defaultCacheConfig()
                .disableCachingNullValues()
                .serializeKeysWith(RedisSerializationContext.SerializationPair
                        .fromSerializer(new StringRedisSerializer()))
                .serializeValuesWith(RedisSerializationContext.SerializationPair
                        .fromSerializer(new GenericJackson2JsonRedisSerializer()));

        Duration metadataTtl = Duration.ofSeconds(props.getMetadataTtlSeconds());

        return RedisCacheManager.builder(connectionFactory)
                .cacheDefaults(defaults)
                .withInitialCacheConfigurations(Map.of(
                        "tables", defaults.entryTtl(metadataTtl),
                        "columns", defaults.entryTtl(metadataTtl)))
                .build();
    }
}
