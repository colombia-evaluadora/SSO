package com.co.eurekatic.auth.security;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.data.redis.core.StringRedisTemplate;

import java.time.Duration;
import java.util.LinkedHashSet;
import java.util.Set;

/**
 * Redis-fronted decorator for {@link EffectiveRolesResolver}. Caches
 * the resolved role set per email so login / refresh / getApiToken
 * no longer hit Postgres for every call.
 *
 * <h2>Why a {@code @Primary} subclass instead of an interface</h2>
 * <p>{@link EffectiveRolesResolver} is a concrete class with one
 * collaborator ({@link com.co.eurekatic.common.repository.UserRepository}).
 * Introducing an interface just to swap the bean would be
 * ceremony without payoff — Spring's {@code @Primary} resolves
 * injection sites unambiguously, and the same constructor signature
 * keeps wiring sites (filter, controllers) untouched.
 *
 * <h2>Failure mode</h2>
 * <p>When Redis throws, we log a WARN and fall back to the wrapped
 * resolver. This is a deliberate departure from
 * {@link RedisRefreshTokenStore} (fail-closed): refresh tokens are
 * an authority artifact, so a Redis outage on mint or rotate MUST
 * block the auth flow. A cached role set is a performance
 * optimization whose staleness is bounded by the TTL — a missed
 * cache invalidation self-heals within an hour.
 *
 * <h2>Cache key shape</h2>
 * <p>{@code <prefix>:<email>} — see {@link SessionCacheProperties#keyPrefix()}.
 * Email is the natural primary key (it is the unique login
 * identifier since the V12 migration) and is the same lookup key
 * the resolver uses, so there is no alias to maintain.
 *
 * <h2>Stampede</h2>
 * <p>Not handled in this commit. The TTL is short (1h) and the
 * worst case is one Postgres fetch per cache-miss per user;
 * tracking a single-flight or jitter is a known follow-up.
 */
public class CachedEffectiveRolesResolver extends EffectiveRolesResolver {

    private static final Logger log = LoggerFactory.getLogger(CachedEffectiveRolesResolver.class);

    private final EffectiveRolesResolver delegate;
    private final StringRedisTemplate redis;
    private final ObjectMapper mapper;
    private final SessionCacheProperties props;

    public CachedEffectiveRolesResolver(EffectiveRolesResolver delegate,
                                        StringRedisTemplate redis,
                                        ObjectMapper mapper,
                                        SessionCacheProperties props) {
        super(delegateRepository(delegate));
        this.delegate = delegate;
        this.redis = redis;
        this.mapper = mapper;
        this.props = props;
    }

    /**
     * Extracts the wrapped delegate's {@code UserRepository} so the
     * superclass can satisfy its own constructor. The superclass is
     * only used for inheritance of the public method signature here
     * — every actual call is dispatched to {@link #delegate}.
     */
    private static com.co.eurekatic.common.repository.UserRepository delegateRepository(
            EffectiveRolesResolver delegate) {
        try {
            var f = EffectiveRolesResolver.class.getDeclaredField("userRepository");
            f.setAccessible(true);
            return (com.co.eurekatic.common.repository.UserRepository) f.get(delegate);
        } catch (ReflectiveOperationException e) {
            // Reaching here means the field name changed without
            // updating this reflection — fail loudly so the next
            // developer notices immediately.
            throw new IllegalStateException(
                    "EffectiveRolesResolver.userRepository field not found", e);
        }
    }

    @Override
    public Set<String> forEmail(String email) {
        if (!props.enabled() || email == null || email.isBlank()) {
            return delegate.forEmail(email);
        }

        String key = key(email);
        String cached;
        try {
            cached = redis.opsForValue().get(key);
        } catch (DataAccessException e) {
            log.warn("Redis unavailable on user-roles cache read; falling back to DB email={}",
                    email, e);
            return delegate.forEmail(email);
        }
        if (cached != null) {
            try {
                Set<String> hit = mapper.readValue(cached, new TypeReference<Set<String>>() {});
                return new LinkedHashSet<>(hit);
            } catch (JsonProcessingException e) {
                // Corrupt cache entry — log and treat as miss so
                // the next write overwrites it. Better than
                // refusing to log in over a single bad row.
                log.warn("Corrupt user-roles cache entry; treating as miss email={}", email, e);
            }
        }

        Set<String> fresh = delegate.forEmail(email);
        try {
            redis.opsForValue().set(key,
                    mapper.writeValueAsString(fresh),
                    Duration.ofSeconds(props.ttlSeconds()));
        } catch (JsonProcessingException e) {
            // Role names are plain strings; serialization should
            // not fail. If it does, the cache stays empty for this
            // email until the next call. Don't block the login.
            log.warn("Failed to serialize user-roles cache entry email={}", email, e);
        } catch (DataAccessException e) {
            log.warn("Redis unavailable on user-roles cache write; serving from DB email={}",
                    email, e);
        }
        return fresh;
    }

    /** Exposed so {@link UserRolesCacheInvalidator} can build the same key. */
    String key(String email) {
        return props.keyPrefix() + ":" + email;
    }
}