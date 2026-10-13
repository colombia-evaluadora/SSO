package com.co.eurekatic.gateway.routing;

import org.junit.jupiter.api.Test;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.web.server.MockServerWebExchange;
import org.springframework.web.server.WebFilterChain;
import reactor.core.publisher.Mono;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/** Cache headers, in-memory caching and path-traversal rejection of {@link AdminUiGlobalFilter}. */
class AdminUiGlobalFilterTest {

    private final AdminUiGlobalFilter filter = new AdminUiGlobalFilter();

    private WebFilterChain chain() {
        WebFilterChain chain = mock(WebFilterChain.class);
        when(chain.filter(any())).thenReturn(Mono.empty());
        return chain;
    }

    private MockServerWebExchange run(String uri, WebFilterChain chain) {
        MockServerWebExchange exchange = MockServerWebExchange.from(MockServerHttpRequest.get(uri).build());
        filter.filter(exchange, chain).block();
        return exchange;
    }

    @Test
    void hashedAssetIsServedImmutable() {
        MockServerWebExchange ex = run("/admin/assets/app-abc123.js", chain());
        assertThat(ex.getResponse().getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(ex.getResponse().getHeaders().getFirst(HttpHeaders.CACHE_CONTROL))
                .isEqualTo("public, max-age=31536000, immutable");
        assertThat(ex.getResponse().getBodyAsString().block()).isEqualTo("console.log(1)");
    }

    @Test
    void indexAndSpaFallbackAreNoCache() {
        MockServerWebExchange ex = run("/admin/some/deep/link", chain());
        assertThat(ex.getResponse().getHeaders().getFirst(HttpHeaders.CACHE_CONTROL)).isEqualTo("no-cache");
        assertThat(ex.getResponse().getBodyAsString().block()).isEqualTo("<html>spa</html>");
    }

    @Test
    void secondRequestIsServedFromCache() {
        run("/admin/assets/app-abc123.js", chain());
        MockServerWebExchange ex = run("/admin/assets/app-abc123.js", chain());
        assertThat(ex.getResponse().getBodyAsString().block()).isEqualTo("console.log(1)");
    }

    @Test
    void traversalSuffixesAreRejectedWith404() {
        for (String uri : new String[] {
                "/admin/assets/../index.html",
                "/admin/assets/%2e%2e/index.html",
                "/admin/assets/..%2findex.html",
                "/admin/assets/a%5c..%5cindex.html",
                "/admin/assets/%5cwindows",
                "/admin/assets/"}) {
            WebFilterChain chain = chain();
            MockServerWebExchange ex = run(uri, chain);
            assertThat(ex.getResponse().getStatusCode()).as(uri).isEqualTo(HttpStatus.NOT_FOUND);
            verify(chain, never()).filter(any());
        }
    }

    @Test
    void safeAssetPathNormalizes() {
        assertThat(AdminUiGlobalFilter.safeAssetPath("/admin/assets/x/y.js"))
                .isEqualTo("static/admin/assets/x/y.js");
        assertThat(AdminUiGlobalFilter.safeAssetPath("/admin/assets/a/../b.js")).isNull();
        assertThat(AdminUiGlobalFilter.safeAssetPath("/admin/assets//etc")).isNull();
    }

    @Test
    void nonAdminPathsPassThrough() {
        WebFilterChain chain = chain();
        run("/api/query", chain);
        verify(chain).filter(any());
    }
}
