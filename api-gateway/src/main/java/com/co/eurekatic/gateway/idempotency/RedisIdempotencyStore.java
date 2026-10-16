package com.co.eurekatic.gateway.idempotency;

import org.springframework.data.redis.core.ReactiveStringRedisTemplate;
import reactor.core.publisher.Mono;

import java.time.Duration;

/** {@link IdempotencyStore} sobre el sso-redis compartido (claves con TTL). */
public class RedisIdempotencyStore implements IdempotencyStore {

    private static final String PREFIX = "idem:";

    private final ReactiveStringRedisTemplate redis;

    public RedisIdempotencyStore(ReactiveStringRedisTemplate redis) {
        this.redis = redis;
    }

    @Override
    public Mono<Boolean> reserve(String key, StoredResponse pending, Duration ttl) {
        return redis.opsForValue().setIfAbsent(PREFIX + key, pending.serialize(), ttl);
    }

    @Override
    public Mono<StoredResponse> get(String key) {
        return redis.opsForValue().get(PREFIX + key).map(StoredResponse::parse);
    }

    @Override
    public Mono<Void> complete(String key, StoredResponse done, Duration ttl) {
        return redis.opsForValue().set(PREFIX + key, done.serialize(), ttl).then();
    }

    @Override
    public Mono<Void> release(String key) {
        return redis.delete(PREFIX + key).then();
    }
}
