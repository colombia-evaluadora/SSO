package com.co.eurekatic.auth.security;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

/**
 * Drops a single email's cached role set. Called by
 * {@link com.co.eurekatic.auth.web.CacheAdminController} on a
 * POST from sso-admin after any role / group binding mutation.
 *
 * <p>Failures are logged WARN, not rethrown — an unreachable
 * Redis must NOT block admin writes (the cache is an
 * optimization, not a source of truth; the TTL bounds staleness).
 */
@Component
public class UserRolesCacheInvalidator {

    private static final Logger log = LoggerFactory.getLogger(UserRolesCacheInvalidator.class);

    private final StringRedisTemplate redis;
    private final SessionCacheProperties props;

    public UserRolesCacheInvalidator(StringRedisTemplate redis, SessionCacheProperties props) {
        this.redis = redis;
        this.props = props;
    }

    public void invalidate(String email) {
        if (email == null || email.isBlank()) {
            return;
        }
        if (!props.enabled()) {
            return;
        }
        String key = props.keyPrefix() + ":" + email;
        try {
            redis.delete(key);
        } catch (DataAccessException e) {
            log.warn("Redis unavailable on user-roles cache invalidation email={}", email, e);
        }
    }
}