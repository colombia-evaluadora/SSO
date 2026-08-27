package com.co.eurekatic.files;

import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.data.redis.serializer.RedisSerializer;
import org.springframework.data.redis.serializer.StringRedisSerializer;

/**
 * Wires the {@link RedisTemplate} {@link CachedFileBlobService} uses
 * to store raw file bytes in the shared {@code sso-redis} instance.
 *
 * <p>Deliberately NOT the Spring Cache SPI (no {@code @EnableCaching},
 * no {@code RedisCacheManager}) — same reasoning as query-service's
 * {@code CatalogResultCacheService}: {@code @Cacheable} has no way to
 * skip caching a value based on its SIZE (the whole point of
 * {@link FileCacheProperties#getMaxCacheableBytes()}), and a plain
 * {@code byte[]} needs a byte-array serializer, not JSON — this
 * service caches opaque file bytes, not a Java object with a shape
 * worth describing to Jackson.
 */
@Configuration
@EnableConfigurationProperties(FileCacheProperties.class)
public class FileCacheConfig {

    @Bean
    public RedisTemplate<String, byte[]> fileBlobRedisTemplate(RedisConnectionFactory connectionFactory) {
        RedisTemplate<String, byte[]> template = new RedisTemplate<>();
        template.setConnectionFactory(connectionFactory);
        template.setKeySerializer(new StringRedisSerializer());
        template.setValueSerializer(RedisSerializer.byteArray());
        template.afterPropertiesSet();
        return template;
    }
}
