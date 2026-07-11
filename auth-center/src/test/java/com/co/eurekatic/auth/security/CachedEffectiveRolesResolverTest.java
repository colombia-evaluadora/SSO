package com.co.eurekatic.auth.security;

import com.co.eurekatic.common.entity.Group;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.UserRepository;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.dao.QueryTimeoutException;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;

import java.time.Duration;
import java.util.LinkedHashSet;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Unit tests for {@link CachedEffectiveRolesResolver}. The wrapped
 * delegate and the {@link StringRedisTemplate} are mocked — no
 * Spring context, no Redis, no DB. Goal: pin the cache contract
 * (miss vs hit, TTL, Redis-down fallback) without dragging
 * Testcontainers into a class that doesn't need it.
 */
@ExtendWith(MockitoExtension.class)
class CachedEffectiveRolesResolverTest {

    @Mock UserRepository userRepository;
    @Mock StringRedisTemplate redis;
    @Mock ValueOperations<String, String> valueOps;

    EffectiveRolesResolver delegate;
    CachedEffectiveRolesResolver cached;

    SessionCacheProperties props;

    @BeforeEach
    void setUp() {
        // Build a real delegate so the decorator's
        // constructor-redirected super field has a real
        // UserRepository to grab via reflection.
        delegate = new EffectiveRolesResolver(userRepository);
        props = new SessionCacheProperties(
                3600L, "sso:session:user-roles", "secret", true, 60L);
        cached = new CachedEffectiveRolesResolver(delegate, redis, new ObjectMapper(), props);
    }

    private Role role(String name) {
        Role r = new Role();
        r.setName(name);
        return r;
    }

    private User userWithRoles(String email, Role... roles) {
        User u = new User();
        u.setEmail(email);
        for (Role r : roles) {
            u.addRole(r);
        }
        return u;
    }

    @Test
    void cacheMissQueriesDbAndWritesToRedisWithTtl() {
        when(redis.opsForValue()).thenReturn(valueOps);
        when(valueOps.get(anyString())).thenReturn(null);
        when(userRepository.findByEmailWithEffectiveRoles("alice"))
                .thenReturn(Optional.of(userWithRoles("alice", role("ADMIN"), role("USER"))));

        Set<String> roles = cached.forEmail("alice");

        assertThat(roles).containsExactlyInAnyOrder("ADMIN", "USER");
        verify(valueOps, times(1)).set(
                eq("sso:session:user-roles:alice"),
                anyString(),
                eq(Duration.ofSeconds(3600L)));
    }

    @Test
    void cacheHitReturnsWithoutHittingDb() {
        when(redis.opsForValue()).thenReturn(valueOps);
        // Set<String> serialised as JSON array of strings.
        when(valueOps.get("sso:session:user-roles:bob")).thenReturn("[\"USER\"]");

        Set<String> roles = cached.forEmail("bob");

        assertThat(roles).containsExactly("USER");
        verify(userRepository, never()).findByEmailWithEffectiveRoles(anyString());
        verify(valueOps, never()).set(anyString(), anyString(), any(Duration.class));
    }

    @Test
    void redisReadFailureFallsBackToDb() {
        when(redis.opsForValue()).thenReturn(valueOps);
        when(valueOps.get(anyString())).thenThrow(new QueryTimeoutException("redis down"));
        when(userRepository.findByEmailWithEffectiveRoles("alice"))
                .thenReturn(Optional.of(userWithRoles("alice", role("ADMIN"))));

        Set<String> roles = cached.forEmail("alice");

        // Fall-through to the delegate. Cached roles must still
        // be the ones the DB says — Redis being down must not
        // silently change the answer.
        assertThat(roles).containsExactly("ADMIN");
        verify(userRepository, times(1)).findByEmailWithEffectiveRoles("alice");
    }

    @Test
    void redisWriteFailureReturnsDbResultWithoutThrowing() {
        when(redis.opsForValue()).thenReturn(valueOps);
        when(valueOps.get(anyString())).thenReturn(null);
        // ValueOperations.set(K, V, Duration) returns void, so the
        // when(...).thenThrow(...) stub form won't compile —
        // doThrow() is the void-method equivalent.
        doThrow(new QueryTimeoutException("redis write timeout"))
                .when(valueOps).set(anyString(), anyString(), any(Duration.class));
        when(userRepository.findByEmailWithEffectiveRoles("alice"))
                .thenReturn(Optional.of(userWithRoles("alice", role("USER"))));

        Set<String> roles = cached.forEmail("alice");

        // We still got the right answer; the cache write was
        // swallowed (logged WARN at the call site).
        assertThat(roles).containsExactly("USER");
    }

    @Test
    void disabledCacheBypassesRedisEntirely() {
        props = new SessionCacheProperties(
                3600L, "sso:session:user-roles", "secret", false, 60L);
        cached = new CachedEffectiveRolesResolver(delegate, redis, new ObjectMapper(), props);
        when(userRepository.findByEmailWithEffectiveRoles("alice"))
                .thenReturn(Optional.of(userWithRoles("alice", role("ADMIN"))));

        Set<String> roles = cached.forEmail("alice");

        assertThat(roles).containsExactly("ADMIN");
        // No Redis traffic when the cache is off.
        verify(redis, never()).opsForValue();
    }

    @Test
    void blankEmailBypassesRedisAndDelegates() {
        when(userRepository.findByEmailWithEffectiveRoles(""))
                .thenReturn(Optional.of(new LinkedHashSet<User>().stream().findFirst().orElseGet(User::new)));

        Set<String> roles = cached.forEmail("");

        // The delegate was called and produced an empty set;
        // Redis was never touched for a blank key.
        assertThat(roles).isEmpty();
        verify(redis, never()).opsForValue();
    }

    @Test
    void corruptCacheEntryTreatedAsMissAndOverwritten() {
        when(redis.opsForValue()).thenReturn(valueOps);
        when(valueOps.get(anyString())).thenReturn("not valid json {");
        when(userRepository.findByEmailWithEffectiveRoles("alice"))
                .thenReturn(Optional.of(userWithRoles("alice", role("USER"))));

        Set<String> roles = cached.forEmail("alice");

        // Treated as a miss: the DB was queried and the result
        // was written back to overwrite the bad row.
        assertThat(roles).containsExactly("USER");
        verify(valueOps, times(1)).set(
                anyString(), anyString(), any(Duration.class));
    }
}