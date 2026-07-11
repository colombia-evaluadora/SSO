package com.co.eurekatic.gateway.routing;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.common.security.JwtProperties;
import com.co.eurekatic.common.security.JwtTokenService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.http.HttpHeaders;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.web.server.MockServerWebExchange;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.ReactiveSecurityContextHolder;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Unit test for {@link UserForwardingGlobalFilter}. Verifies that
 * when a valid {@link AuthPrincipal} is in the reactive security
 * context, the filter propagates {@code X-Authenticated-User},
 * {@code X-Authenticated-Roles}, and {@code X-Authenticated-Token-Type}
 * to the downstream request. When no principal is present, the
 * filter is a no-op (no headers added).
 */
class UserForwardingGlobalFilterTest {

    private JwtTokenService jwt;
    private JwtProperties props;
    private UserForwardingGlobalFilter filter;
    private GatewayFilterChain chain;

    @BeforeEach
    void setUp() {
        // Use a real JwtTokenService so we exercise the real
        // claim shape and a real AuthPrincipal.
        props = new JwtProperties(
                "this-is-a-test-secret-that-is-at-least-32-bytes-long-1234",
                "sso-postgres",
                3600L,
                86400L,
                "Authorization",
                "Bearer ");
        jwt = new JwtTokenService(props);
        filter = new UserForwardingGlobalFilter();
        chain = mock(GatewayFilterChain.class);
        when(chain.filter(org.mockito.ArgumentMatchers.any(ServerWebExchange.class)))
                .thenReturn(Mono.empty());
    }

    @Test
    void propagatesUserAndRolesAndTokenTypeToDownstreamRequest() {
        Set<String> roles = new LinkedHashSet<>(List.of("USER", "ADMIN"));
        AuthPrincipal principal = new AuthPrincipal("alice", roles, "access");
        UsernamePasswordAuthenticationToken auth =
                new UsernamePasswordAuthenticationToken(principal, "token",
                        List.<GrantedAuthority>of(new SimpleGrantedAuthority("USER"),
                                new SimpleGrantedAuthority("ADMIN")));

        MockServerHttpRequest request = MockServerHttpRequest
                .get("/some/path")
                .build();
        ServerWebExchange exchange = MockServerWebExchange.from(request);

        Mono<Void> result = filter.filter(exchange, chain)
                .contextWrite(ReactiveSecurityContextHolder
                        .withSecurityContext(Mono.just(
                                new org.springframework.security.core.context.SecurityContextImpl(auth))));

        // Drive the Mono to completion.
        result.block();

        // Capture the mutated exchange passed to chain.filter.
        ArgumentCaptor<ServerWebExchange> captor =
                ArgumentCaptor.forClass(ServerWebExchange.class);
        verify(chain).filter(captor.capture());

        ServerWebExchange forwarded = captor.getValue();
        HttpHeaders headers = forwarded.getRequest().getHeaders();
        assertThat(headers.getFirst(UserForwardingGlobalFilter.HEADER_USER))
                .isEqualTo("alice");
        assertThat(headers.getFirst(UserForwardingGlobalFilter.HEADER_ROLES))
                .contains("USER")
                .contains("ADMIN");
        assertThat(headers.getFirst(UserForwardingGlobalFilter.HEADER_TOKEN_TYPE))
                .isEqualTo("access");
    }

    @Test
    void addsNoUserHeadersWhenNoAuthenticatedPrincipal() {
        // No security context at all (empty Mono).
        MockServerHttpRequest request = MockServerHttpRequest
                .get("/some/path")
                .build();
        ServerWebExchange exchange = MockServerWebExchange.from(request);

        Mono<Void> result = filter.filter(exchange, chain);
        result.block();

        // The chain should have been called with the original
        // exchange (no user headers added).
        ArgumentCaptor<ServerWebExchange> captor =
                ArgumentCaptor.forClass(ServerWebExchange.class);
        verify(chain).filter(captor.capture());

        ServerWebExchange forwarded = captor.getValue();
        HttpHeaders headers = forwarded.getRequest().getHeaders();
        assertThat(headers.getFirst(UserForwardingGlobalFilter.HEADER_USER)).isNull();
        assertThat(headers.getFirst(UserForwardingGlobalFilter.HEADER_ROLES)).isNull();
        assertThat(headers.getFirst(UserForwardingGlobalFilter.HEADER_TOKEN_TYPE)).isNull();
    }

    @Test
    void addsNoUserHeadersWhenPrincipalIsNotAuthPrincipal() {
        // Spring Security's default principal when the user is
        // unauthenticated is "anonymousUser" (a String). The
        // global filter should treat this as "no auth" and not
        // add user headers.
        UsernamePasswordAuthenticationToken anonAuth =
                UsernamePasswordAuthenticationToken.unauthenticated("anonymousUser", null);
        // `unauthenticated` returns a token with no authorities.

        MockServerHttpRequest request = MockServerHttpRequest
                .get("/some/path")
                .build();
        ServerWebExchange exchange = MockServerWebExchange.from(request);

        Mono<Void> result = filter.filter(exchange, chain)
                .contextWrite(ReactiveSecurityContextHolder
                        .withSecurityContext(Mono.just(
                                new org.springframework.security.core.context.SecurityContextImpl(anonAuth))));

        result.block();

        ArgumentCaptor<ServerWebExchange> captor =
                ArgumentCaptor.forClass(ServerWebExchange.class);
        verify(chain).filter(captor.capture());

        ServerWebExchange forwarded = captor.getValue();
        HttpHeaders headers = forwarded.getRequest().getHeaders();
        assertThat(headers.getFirst(UserForwardingGlobalFilter.HEADER_USER)).isNull();
    }
}
