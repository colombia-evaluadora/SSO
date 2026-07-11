package com.co.eurekatic.ssoadmin.config;

import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.cache.annotation.EnableCaching;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.cache.RedisCacheConfiguration;
import org.springframework.data.redis.cache.RedisCacheManager;
import org.springframework.data.redis.connection.RedisConnectionFactory;

import java.util.Map;

/**
 * Redis-backed {@link org.springframework.cache.CacheManager} for
 * every {@code @Cacheable} lookup in sso-admin. Same Redis
 * instance auth-center already uses for refresh tokens + its own
 * {@code user-by-email} cache — the per-cache names are Spring's
 * default key prefix, so {@code "app-access"},
 * {@code "roles"}, and {@code "user-by-email"} never collide
 * with auth-center's own {@code sso:refresh:*} /
 * {@code sso:session:user-roles:*} keys.
 *
 * <p>Values are cached with {@link RedisCacheConfiguration}'s own
 * default serializer (JDK serialization) — deliberately NOT
 * {@code GenericJackson2JsonRedisSerializer}, which Spring Data
 * Redis 4 deprecated in favor of a Jackson-3-based replacement that
 * needs its own {@code tools.jackson.databind.ObjectMapper} bean.
 * Not worth the extra dependency for the values cached today
 * (booleans, immutable records of strings).
 *
 * <p>Per-cache TTLs come from {@link AdminAccessProperties}:
 * <ul>
 *   <li>{@code app-access} — see {@code AppAccessService}</li>
 *   <li>{@code roles} — see {@code RoleLookupService}</li>
 *   <li>{@code user-by-email} — see {@code UserLookupService}</li>
 * </ul>
 */
@Configuration
@EnableCaching
@EnableConfigurationProperties(AdminAccessProperties.class)
public class CacheConfig {

    @Bean
    public RedisCacheManager cacheManager(RedisConnectionFactory connectionFactory,
                                          AdminAccessProperties props) {
        RedisCacheConfiguration defaults = RedisCacheConfiguration.defaultCacheConfig()
                .disableCachingNullValues();
        return RedisCacheManager.builder(connectionFactory)
                .cacheDefaults(defaults.entryTtl(props.appAccessCacheTtl()))
                .withInitialCacheConfigurations(Map.of(
                        "app-access", defaults.entryTtl(props.appAccessCacheTtl()),
                        "roles", defaults.entryTtl(props.rolesCacheTtl()),
                        "user-by-email", defaults.entryTtl(props.userByEmailCacheTtl())))
                .build();
    }
}
