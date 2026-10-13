package com.co.eurekatic.query.catalog;

import com.co.eurekatic.common.security.AuthPrincipal;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.web.server.ResponseStatusException;

import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class CatalogDefinitionCacheTest {

    private static Authentication user(String email) {
        return new UsernamePasswordAuthenticationToken(
                new AuthPrincipal(email, Set.of(), "ACCESS"), "tok", Set.of());
    }

    private static QueryDefinition def(String uuid) {
        return new QueryDefinition(1L, uuid, "SELECT 1", "postgres", false, false,
                null, null, null);
    }

    private static CatalogDefinitionCache cache(CatalogClient client, boolean enabled) {
        return new CatalogDefinitionCache(client, new SimpleMeterRegistry(), enabled, 60, 100);
    }

    @Test
    void secondCallForSameUserHitsCache() {
        CatalogClient client = mock(CatalogClient.class);
        when(client.fetchQuery(any(), any())).thenReturn(def("u1"));
        CatalogDefinitionCache c = cache(client, true);
        c.query(user("a@x.co"), "t", "u1");
        c.query(user("a@x.co"), "t", "u1");
        verify(client, times(1)).fetchQuery("t", "u1");
    }

    @Test
    void otherUserDoesNotShareEntry() {
        CatalogClient client = mock(CatalogClient.class);
        when(client.fetchQuery(any(), any())).thenReturn(def("u1"));
        CatalogDefinitionCache c = cache(client, true);
        c.query(user("a@x.co"), "t", "u1");
        c.query(user("b@x.co"), "t", "u1");
        verify(client, times(2)).fetchQuery("t", "u1");
    }

    @Test
    void refusalsAreNotCached() {
        CatalogClient client = mock(CatalogClient.class);
        when(client.fetchQuery(any(), any()))
                .thenThrow(new ResponseStatusException(HttpStatus.FORBIDDEN))
                .thenReturn(def("u1"));
        CatalogDefinitionCache c = cache(client, true);
        assertThatThrownBy(() -> c.query(user("a@x.co"), "t", "u1"))
                .isInstanceOf(ResponseStatusException.class);
        assertThat(c.query(user("a@x.co"), "t", "u1")).isNotNull();
    }

    @Test
    void invalidateAllForcesReload() {
        CatalogClient client = mock(CatalogClient.class);
        when(client.fetchQuery(any(), any())).thenReturn(def("u1"));
        CatalogDefinitionCache c = cache(client, true);
        c.query(user("a@x.co"), "t", "u1");
        c.invalidateAll();
        c.query(user("a@x.co"), "t", "u1");
        verify(client, times(2)).fetchQuery("t", "u1");
    }

    @Test
    void disabledAlwaysCallsCatalog() {
        CatalogClient client = mock(CatalogClient.class);
        when(client.fetchQuery(any(), any())).thenReturn(def("u1"));
        CatalogDefinitionCache c = cache(client, false);
        c.query(null, "", "u1");
        c.query(null, "", "u1");
        verify(client, times(2)).fetchQuery("", "u1");
    }
}
