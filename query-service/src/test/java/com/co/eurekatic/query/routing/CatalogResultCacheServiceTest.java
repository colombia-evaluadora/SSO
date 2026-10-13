package com.co.eurekatic.query.routing;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.query.config.QueryCacheProperties;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.core.Authentication;

import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
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
        when(valueOps.multiGet(org.mockito.ArgumentMatchers.<List<String>>any()))
                .thenThrow(new RuntimeException("redis down"));

        assertThat(service("eval-col").get("menus:abc")).isEmpty();
    }

    @Test
    void getReadsTheKeyThatEmbedsBothGenerations() {
        when(redis.opsForValue()).thenReturn(valueOps);
        when(valueOps.multiGet(List.of("query:catalog-gen:eval-col:menus",
                "query:catalog-gen:eval-col:__all__")))
                .thenReturn(java.util.Arrays.asList("3", "5"));
        when(valueOps.get("query:catalog-get:eval-col:menus:g3.5:abc")).thenReturn("{\"rows\":[]}");

        assertThat(service("eval-col").get("menus:abc")).isPresent();
    }

    @Test
    void putUsesGenerationZeroWhenCountersDoNotExist() {
        when(redis.opsForValue()).thenReturn(valueOps);
        when(valueOps.multiGet(org.mockito.ArgumentMatchers.<List<String>>any()))
                .thenReturn(java.util.Arrays.asList(null, null));

        service("eval-col").put("menus:abc", Map.of("rows", List.of()), 60);

        verify(valueOps).set(eq("query:catalog-get:eval-col:menus:g0.0:abc"), anyString(),
                eq(java.time.Duration.ofSeconds(60)));
    }

    @Test
    void putUsesGlobalScopeWhenNoInstanceNameConfigured() {
        when(redis.opsForValue()).thenReturn(valueOps);
        when(valueOps.multiGet(org.mockito.ArgumentMatchers.<List<String>>any()))
                .thenReturn(java.util.Arrays.asList(null, null));

        service(null).put("menus:abc", Map.of("rows", List.of()), 60);

        verify(valueOps).set(eq("query:catalog-get:global:menus:g0.0:abc"), anyString(),
                eq(java.time.Duration.ofSeconds(60)));
    }

    @Test
    void keyForDoesNotCollideOnParamValuesContainingSeparators() {
        Authentication auth = null;
        String k1 = CatalogResultCacheService.keyFor("u", "/x",
                Map.of("a", "1, b=2"), auth);
        String k2 = CatalogResultCacheService.keyFor("u", "/x",
                Map.of("a", "1", "b", "2"), auth);
        assertThat(k1).isNotEqualTo(k2);
    }

    /* ====================== invalidation por generacion ====================== */

    @Test
    void invalidateAllIncrementsTheGlobalGeneration() {
        when(redis.opsForValue()).thenReturn(valueOps);

        service("eval-col").invalidateAll();

        verify(valueOps).increment("query:catalog-gen:eval-col:__all__");
    }

    @Test
    void invalidateForResourceIncrementsOnlyThatResourcesGeneration() {
        when(redis.opsForValue()).thenReturn(valueOps);

        service("eval-col").invalidateForResource("/menus/:ID/eliminar");

        verify(valueOps).increment("query:catalog-gen:eval-col:menus");
        verify(valueOps, never()).increment("query:catalog-gen:eval-col:__all__");
    }

    @Test
    void invalidateForResourceFallsBackToGlobalWhenPathTemplateIsMissing() {
        when(redis.opsForValue()).thenReturn(valueOps);

        service("eval-col").invalidateForResource(null);

        verify(valueOps).increment("query:catalog-gen:eval-col:__all__");
    }

    @Test
    void invalidateFailsOpenOnRedisError() {
        when(redis.opsForValue()).thenReturn(valueOps);
        when(valueOps.increment(anyString())).thenThrow(new RuntimeException("redis down"));

        // No debe lanzar: la escritura ya se confirmó en Postgres.
        service("eval-col").invalidateAll();
    }

    @Test
    void invalidateIsNoOpWhenCatalogCachingDisabled() {
        props.setCatalogEnabled(false);

        service("eval-col").invalidateAll();
        service("eval-col").invalidateForResource("/menus");

        verify(redis, never()).opsForValue();
    }

    @Test
    void putIsNoOpWhenCatalogCachingDisabled() {
        props.setCatalogEnabled(false);
        CatalogResultCacheService svc = service("eval-col");

        svc.put("abc123", Map.of("rows", List.of()), 60);

        verify(redis, never()).opsForValue();
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

}
