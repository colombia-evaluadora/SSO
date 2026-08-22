package com.co.eurekatic.query.routing;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.query.config.QueryCacheProperties;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.redis.core.Cursor;
import org.springframework.data.redis.core.ScanOptions;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.core.Authentication;

import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Unit tests for {@link CatalogResultCacheService}. Redis is
 * mocked — no Testcontainers, no real connection — same pattern as
 * auth-center's {@code CachedEffectiveRolesResolverTest}. Goal:
 * pin the cache-key safety contract ({@link #keyFor} distinctness
 * by caller/params — the property the docker-compose smoke test in
 * the PR description verified end-to-end), the instance-scoped key
 * prefix, and the write-triggered {@link
 * CatalogResultCacheService#invalidateAll()} fail-open behavior.
 */
@ExtendWith(MockitoExtension.class)
class CatalogResultCacheServiceTest {

    @Mock StringRedisTemplate redis;
    @Mock ValueOperations<String, String> valueOps;

    QueryCacheProperties props;

    @BeforeEach
    void setUp() {
        props = new QueryCacheProperties();
        props.setCatalogEnabled(true);
    }

    private CatalogResultCacheService service(String instanceName) {
        return new CatalogResultCacheService(redis, new ObjectMapper(), props, instanceName);
    }

    /* ====================== keyFor ====================== */

    @Test
    void keyForIsDeterministicForTheSameInputs() {
        Authentication auth = principal(7L, "alice@example.com");
        String k1 = CatalogResultCacheService.keyFor("uuid-1", "/select", Map.of(), auth);
        String k2 = CatalogResultCacheService.keyFor("uuid-1", "/select", Map.of(), auth);
        assertThat(k1).isEqualTo(k2);
    }

    @Test
    void keyForIgnoresQueryParamOrder() {
        Authentication auth = principal(7L, "alice@example.com");
        String k1 = CatalogResultCacheService.keyFor("uuid-1", "/select",
                Map.of("a", "1", "b", "2"), auth);
        String k2 = CatalogResultCacheService.keyFor("uuid-1", "/select",
                Map.of("b", "2", "a", "1"), auth);
        assertThat(k1).isEqualTo(k2);
    }

    @Test
    void keyForDistinguishesDifferentPathVariableValues() {
        // The scenario that mattered in practice: /select/ZONA and
        // /select/JORNADA must never share a cache entry even
        // though they're dispatches of the exact same catalog uuid.
        Authentication auth = principal(7L, "alice@example.com");
        String zona = CatalogResultCacheService.keyFor("uuid-1", "/select/ZONA", Map.of(), auth);
        String jornada = CatalogResultCacheService.keyFor("uuid-1", "/select/JORNADA", Map.of(), auth);
        assertThat(zona).isNotEqualTo(jornada);
    }

    @Test
    void keyForDistinguishesDifferentCallers() {
        // The core safety property: two authenticated users hitting
        // the identical GET must never share a cache entry, even
        // with identical uuid/path/params — see class javadoc on
        // CatalogResultCacheService for why.
        String alice = CatalogResultCacheService.keyFor("uuid-1", "/menus", Map.of(),
                principal(7L, "alice@example.com"));
        String bob = CatalogResultCacheService.keyFor("uuid-1", "/menus", Map.of(),
                principal(8L, "bob@example.com"));
        assertThat(alice).isNotEqualTo(bob);
    }

    @Test
    void keyForTreatsAnonymousAsItsOwnDistinctCaller() {
        String anon = CatalogResultCacheService.keyFor("uuid-1", "/public-select", Map.of(), null);
        String alice = CatalogResultCacheService.keyFor("uuid-1", "/public-select", Map.of(),
                principal(7L, "alice@example.com"));
        assertThat(anon).isNotEqualTo(alice);
    }

    private static Authentication principal(long userId, String email) {
        AuthPrincipal p = new AuthPrincipal(email, userId, Set.of("USER"), "access");
        return new TestingAuthenticationToken(p, null);
    }

    /* ====================== get / put ====================== */

    @Test
    void getReturnsEmptyWhenCatalogCachingDisabled() {
        props.setCatalogEnabled(false);
        CatalogResultCacheService svc = service("eval-col");

        assertThat(svc.get("some-key")).isEmpty();
        // disabled short-circuits before touching Redis at all
        verify(redis, never()).opsForValue();
    }

    @Test
    void getFailsOpenOnRedisError() {
        when(redis.opsForValue()).thenReturn(valueOps);
        when(valueOps.get(anyString())).thenThrow(new RuntimeException("redis down"));

        CatalogResultCacheService svc = service("eval-col");
        assertThat(svc.get("some-key")).isEmpty();
    }

    @Test
    void putWritesUnderTheInstanceScopedPrefix() {
        when(redis.opsForValue()).thenReturn(valueOps);

        CatalogResultCacheService svc = service("eval-col");
        svc.put("abc123", Map.of("rows", List.of()), 60);

        verify(valueOps).set(eq("query:catalog-get:eval-col:abc123"), anyString(),
                eq(java.time.Duration.ofSeconds(60)));
    }

    @Test
    void putUsesGlobalScopeWhenNoInstanceNameConfigured() {
        when(redis.opsForValue()).thenReturn(valueOps);

        CatalogResultCacheService svc = service(null);
        svc.put("abc123", Map.of("rows", List.of()), 60);

        verify(valueOps).set(eq("query:catalog-get:global:abc123"), anyString(),
                eq(java.time.Duration.ofSeconds(60)));
    }

    @Test
    void putIsNoOpWhenCatalogCachingDisabled() {
        props.setCatalogEnabled(false);
        CatalogResultCacheService svc = service("eval-col");

        svc.put("abc123", Map.of("rows", List.of()), 60);

        verify(redis, never()).opsForValue();
    }

    /* ====================== invalidateAll (V66) ====================== */

    @SuppressWarnings("unchecked")
    @Test
    void invalidateAllDeletesEveryKeyMatchingThisInstancesScope() {
        Cursor<String> cursor = mock(Cursor.class);
        Iterator<String> it = List.of(
                "query:catalog-get:eval-col:key1",
                "query:catalog-get:eval-col:key2").iterator();
        when(cursor.hasNext()).thenAnswer(inv -> it.hasNext());
        when(cursor.next()).thenAnswer(inv -> it.next());
        when(redis.scan(org.mockito.ArgumentMatchers.any(ScanOptions.class))).thenReturn(cursor);
        when(redis.delete(org.mockito.ArgumentMatchers.<List<String>>any())).thenReturn(2L);

        CatalogResultCacheService svc = service("eval-col");
        long removed = svc.invalidateAll();

        assertThat(removed).isEqualTo(2L);
        verify(redis).delete(List.of(
                "query:catalog-get:eval-col:key1",
                "query:catalog-get:eval-col:key2"));
    }

    @SuppressWarnings("unchecked")
    @Test
    void invalidateAllIsNoOpWhenNothingIsCached() {
        Cursor<String> cursor = mock(Cursor.class);
        when(cursor.hasNext()).thenReturn(false);
        when(redis.scan(org.mockito.ArgumentMatchers.any(ScanOptions.class))).thenReturn(cursor);

        CatalogResultCacheService svc = service("eval-col");
        long removed = svc.invalidateAll();

        assertThat(removed).isEqualTo(0L);
        verify(redis, never()).delete(org.mockito.ArgumentMatchers.<List<String>>any());
    }

    @Test
    void invalidateAllFailsOpenOnRedisError() {
        when(redis.scan(org.mockito.ArgumentMatchers.any(ScanOptions.class)))
                .thenThrow(new RuntimeException("redis down"));

        CatalogResultCacheService svc = service("eval-col");

        // Must not throw — a write already committed to Postgres by
        // the time this runs; a Redis outage degrades to "stale
        // until TTL", never a 500 on the write itself.
        long removed = svc.invalidateAll();
        assertThat(removed).isEqualTo(0L);
    }

    @Test
    void invalidateAllIsNoOpWhenCatalogCachingDisabled() {
        props.setCatalogEnabled(false);
        CatalogResultCacheService svc = service("eval-col");

        long removed = svc.invalidateAll();

        assertThat(removed).isEqualTo(0L);
        verify(redis, never()).scan(org.mockito.ArgumentMatchers.any(ScanOptions.class));
    }

    /* ====================== resourceTag ====================== */

    @Test
    void resourceTagIsTheFirstPathSegment() {
        assertThat(CatalogResultCacheService.resourceTag("/menus")).isEqualTo("menus");
        assertThat(CatalogResultCacheService.resourceTag("/menus/:ID")).isEqualTo("menus");
        assertThat(CatalogResultCacheService.resourceTag("/menus/:ID/eliminar")).isEqualTo("menus");
    }

    @Test
    void resourceTagOfANestedWriteIsTheOuterResourceNotTheInnerOne() {
        // /roles/:ROLEID/menus mutates trol_menu (a join on ROLES),
        // not the menus table itself — tagging it "roles" (not
        // "menus") is intentional; see class javadoc's worked
        // example.
        assertThat(CatalogResultCacheService.resourceTag("/roles/:ROLEID/menus")).isEqualTo("roles");
    }

    @Test
    void resourceTagIsCaseInsensitive() {
        assertThat(CatalogResultCacheService.resourceTag("/MENUS")).isEqualTo("menus");
    }

    @Test
    void resourceTagFallsBackToUnknownForNoPath() {
        assertThat(CatalogResultCacheService.resourceTag(null)).isEqualTo("_unknown");
        assertThat(CatalogResultCacheService.resourceTag("")).isEqualTo("_unknown");
        assertThat(CatalogResultCacheService.resourceTag("/")).isEqualTo("_unknown");
    }

    /* ====================== invalidateForResource (V66) ====================== */

    @SuppressWarnings("unchecked")
    @Test
    void invalidateForResourceOnlyScansThisResourcesKeyspace() {
        Cursor<String> cursor = mock(Cursor.class);
        when(cursor.hasNext()).thenReturn(false);
        org.mockito.ArgumentCaptor<ScanOptions> captor =
                org.mockito.ArgumentCaptor.forClass(ScanOptions.class);
        when(redis.scan(captor.capture())).thenReturn(cursor);

        CatalogResultCacheService svc = service("eval-col");
        svc.invalidateForResource("/menus/:ID/eliminar");

        assertThat(captor.getValue().getPattern())
                .isEqualTo("query:catalog-get:eval-col:menus:*");
    }

    @SuppressWarnings("unchecked")
    @Test
    void invalidateForResourceDeletesOnlyMatchingResourceKeysNotUnrelatedOnes() {
        // The exact scenario reported: a write on /menus must not
        // touch cache entries filed under an unrelated resource like
        // /roles — simulated here by the SCAN only ever yielding
        // "menus"-tagged keys (a real Redis would never hand back a
        // "roles"-tagged key for a "menus:*" glob either).
        Cursor<String> cursor = mock(Cursor.class);
        Iterator<String> it = List.of(
                "query:catalog-get:eval-col:menus:key1",
                "query:catalog-get:eval-col:menus:key2").iterator();
        when(cursor.hasNext()).thenAnswer(inv -> it.hasNext());
        when(cursor.next()).thenAnswer(inv -> it.next());
        when(redis.scan(org.mockito.ArgumentMatchers.any(ScanOptions.class))).thenReturn(cursor);
        when(redis.delete(org.mockito.ArgumentMatchers.<List<String>>any())).thenReturn(2L);

        CatalogResultCacheService svc = service("eval-col");
        long removed = svc.invalidateForResource("/menus");

        assertThat(removed).isEqualTo(2L);
        verify(redis).delete(List.of(
                "query:catalog-get:eval-col:menus:key1",
                "query:catalog-get:eval-col:menus:key2"));
    }

    @SuppressWarnings("unchecked")
    @Test
    void invalidateForResourceFallsBackToInvalidateAllWhenPathTemplateIsMissing() {
        Cursor<String> cursor = mock(Cursor.class);
        when(cursor.hasNext()).thenReturn(false);
        org.mockito.ArgumentCaptor<ScanOptions> captor =
                org.mockito.ArgumentCaptor.forClass(ScanOptions.class);
        when(redis.scan(captor.capture())).thenReturn(cursor);

        CatalogResultCacheService svc = service("eval-col");
        svc.invalidateForResource(null);

        assertThat(captor.getValue().getPattern())
                .isEqualTo("query:catalog-get:eval-col:*");
    }

    @Test
    void invalidateForResourceIsNoOpWhenCatalogCachingDisabled() {
        props.setCatalogEnabled(false);
        CatalogResultCacheService svc = service("eval-col");

        long removed = svc.invalidateForResource("/menus");

        assertThat(removed).isEqualTo(0L);
        verify(redis, never()).scan(org.mockito.ArgumentMatchers.any(ScanOptions.class));
    }
}
