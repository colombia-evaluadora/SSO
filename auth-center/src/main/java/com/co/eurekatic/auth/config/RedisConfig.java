package com.co.eurekatic.auth.config;

import com.co.eurekatic.auth.security.CachedEffectiveRolesResolver;
import com.co.eurekatic.auth.security.EffectiveRolesResolver;
import com.co.eurekatic.auth.security.RedisRefreshTokenStore;
import com.co.eurekatic.auth.security.RefreshTokenProperties;
import com.co.eurekatic.auth.security.SessionCacheProperties;
import com.co.eurekatic.common.security.RefreshTokenStore;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.cache.annotation.EnableCaching;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;
import org.springframework.data.redis.cache.RedisCacheConfiguration;
import org.springframework.data.redis.cache.RedisCacheManager;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.serializer.GenericJackson2JsonRedisSerializer;
import org.springframework.data.redis.serializer.RedisSerializationContext;
import org.springframework.data.redis.serializer.StringRedisSerializer;

import java.time.Duration;
import java.util.Map;

/**
 * Wires the refresh-token store backed by Redis and the Spring
 * Cache abstraction used by Phase 2 (@Cacheable on user-by-email
 * lookups in AuthController).
 *
 * <p>The {@link StringRedisTemplate} and the underlying Lettuce
 * {@code RedisConnectionFactory} are auto-configured by Spring Boot 4
 * via {@code spring-boot-starter-data-redis} (no manual factory bean
 * needed). Host/port/password come from {@code spring.data.redis.*}
 * — wired from {@code REDIS_HOST} / {@code REDIS_PORT} /
 * {@code REDIS_PASSWORD} in {@code docker-compose.yml}.
 *
 * <p>The store bean is exposed as the {@link RefreshTokenStore}
 * interface from {@code common} so callers (filter chain, refresh
 * controller) can be unit-tested against a fake without dragging
 * Lettuce into the test classpath.
 *
 * <p>Two distinct Redis use-cases coexist here:
 * <ol>
 *   <li><b>Refresh-token store</b> — raw {@code StringRedisTemplate}
 *       with hand-rolled JSON; see {@link RedisRefreshTokenStore}.</li>
 *   <li><b>Spring Cache</b> — {@link RedisCacheManager} backing
 *       {@code @Cacheable} on local lookups. Same Redis instance,
 *       distinct cache-name namespace; no cross-service
 *       coordination is needed because auth-center is the only
 *       reader <em>and</em> writer of these entries.</li>
 * </ol>
 */
@Configuration
@EnableCaching
@EnableConfigurationProperties({RefreshTokenProperties.class, SessionCacheProperties.class})
public class RedisConfig {

    @Bean
    public RefreshTokenStore refreshTokenStore(
            StringRedisTemplate stringRedisTemplate,
            ObjectMapper objectMapper,
            RefreshTokenProperties refreshTokenProperties) {
        return new RedisRefreshTokenStore(stringRedisTemplate, objectMapper, refreshTokenProperties);
    }

    /**
     * Redis-fronted decorator for {@link EffectiveRolesResolver}.
     * Marked {@link Primary} so the existing injection points
     * (login filter, refresh controller, getApiToken) resolve to
     * the cached variant without touching their constructors.
     */
    @Bean
    @Primary
    public EffectiveRolesResolver cachedEffectiveRolesResolver(
            EffectiveRolesResolver delegate,
            StringRedisTemplate stringRedisTemplate,
            ObjectMapper objectMapper,
            SessionCacheProperties sessionCacheProperties) {
        return new CachedEffectiveRolesResolver(delegate, stringRedisTemplate,
                objectMapper, sessionCacheProperties);
    }

    /**
     * Redis-backed {@link org.springframework.cache.CacheManager}
     * for Phase 2 {@code @Cacheable} lookups in auth-center
     * (currently {@code GET /getInfoUser}). Key/value pairs use
     * JSON serialization so a cached {@code UserSummary} survives
     * across JVMs without depending on class identity.
     *
     * <p>Per-cache TTLs come from {@link SessionCacheProperties}:
     * {@code user-by-email} is a short window (60s) because user
     * attributes change occasionally but each cached entry is small
     * and the data is mostly profile display, not authorization.
     */
    @Bean
    public RedisCacheManager cacheManager(RedisConnectionFactory connectionFactory,
                                          SessionCacheProperties props,
                                          ObjectMapper objectMapper) {
        GenericJackson2JsonRedisSerializer json =
                new GenericJackson2JsonRedisSerializer(objectMapper);
        RedisCacheConfiguration defaults = RedisCacheConfiguration.defaultCacheConfig()
                .disableCachingNullValues()
                .serializeKeysWith(RedisSerializationContext.SerializationPair
                        .fromSerializer(new StringRedisSerializer()))
                .serializeValuesWith(RedisSerializationContext.SerializationPair
                        .fromSerializer(json));
        return RedisCacheManager.builder(connectionFactory)
                .cacheDefaults(defaults)
                .withInitialCacheConfigurations(Map.of(
                        "user-by-email",
                        defaults.entryTtl(Duration.ofSeconds(props.userByEmailTtlSeconds()))))
                .build();
    }
}