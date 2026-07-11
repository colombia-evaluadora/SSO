package com.co.eurekatic.auth.security;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.dao.QueryTimeoutException;
import org.springframework.data.redis.core.StringRedisTemplate;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Unit tests for {@link UserRolesCacheInvalidator}. Confirms the
 * delegate contract — drops the right key, swallows Redis
 * outages, no-ops on disabled cache / blank input.
 */
@ExtendWith(MockitoExtension.class)
class UserRolesCacheInvalidatorTest {

    @Mock StringRedisTemplate redis;

    SessionCacheProperties props;

    UserRolesCacheInvalidator invalidator;

    @BeforeEach
    void setUp() {
        props = new SessionCacheProperties(
                3600L, "sso:session:user-roles", "secret", true, 60L);
        invalidator = new UserRolesCacheInvalidator(redis, props);
    }

    @Test
    void invalidateDeletesTheRightKey() {
        invalidator.invalidate("alice@example.com");

        verify(redis, times(1)).delete("sso:session:user-roles:alice@example.com");
    }

    @Test
    void invalidateSwallowsRedisErrors() {
        when(redis.delete(eq("sso:session:user-roles:bob@example.com")))
                .thenThrow(new QueryTimeoutException("redis down"));

        // The whole point of the invalidator is that a Redis
        // outage does NOT bubble up into admin writes. Pin it.
        assertThatCode(() -> invalidator.invalidate("bob@example.com"))
                .doesNotThrowAnyException();
    }

    @Test
    void invalidateIgnoresBlankEmail() {
        invalidator.invalidate(null);
        invalidator.invalidate("");
        invalidator.invalidate("   ");

        verify(redis, never()).delete(org.mockito.ArgumentMatchers.anyString());
    }

    @Test
    void invalidateSkipsRedisWhenCacheDisabled() {
        props = new SessionCacheProperties(
                3600L, "sso:session:user-roles", "secret", false, 60L);
        invalidator = new UserRolesCacheInvalidator(redis, props);

        invalidator.invalidate("alice@example.com");

        verify(redis, never()).delete(org.mockito.ArgumentMatchers.anyString());
    }
}