package com.co.eurekatic.gateway.routing;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.http.HttpHeaders;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.web.server.MockServerWebExchange;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

import java.net.InetSocketAddress;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Unit test for {@link ClientIpGlobalFilter}. Verifies the security
 * property this filter exists for: the gateway's own view of the
 * TCP peer always wins, a client-supplied {@code X-Client-Ip} is
 * never trusted as-is.
 */
class ClientIpGlobalFilterTest {

    private ClientIpGlobalFilter filter;
    private GatewayFilterChain chain;

    @BeforeEach
    void setUp() {
        filter = new ClientIpGlobalFilter();
        chain = mock(GatewayFilterChain.class);
        when(chain.filter(org.mockito.ArgumentMatchers.any(ServerWebExchange.class)))
                .thenReturn(Mono.empty());
    }

    @Test
    void setsXClientIpFromRealRemoteAddress() {
        MockServerHttpRequest request = MockServerHttpRequest.get("/some/path")
                .remoteAddress(new InetSocketAddress("198.51.100.7", 54321))
                .build();
        ServerWebExchange exchange = MockServerWebExchange.from(request);

        filter.filter(exchange, chain).block();

        ArgumentCaptor<ServerWebExchange> captor = ArgumentCaptor.forClass(ServerWebExchange.class);
        verify(chain).filter(captor.capture());

        HttpHeaders headers = captor.getValue().getRequest().getHeaders();
        assertThat(headers.getFirst(ClientIpGlobalFilter.HEADER_X_CLIENT_IP))
                .isEqualTo("198.51.100.7");
    }

    @Test
    void overwritesAnySpoofedClientSuppliedHeader() {
        // A caller lying about its IP must never survive past the
        // gateway — this is the whole point of the filter.
        MockServerHttpRequest request = MockServerHttpRequest.get("/some/path")
                .header(ClientIpGlobalFilter.HEADER_X_CLIENT_IP, "10.0.0.1, 6.6.6.6")
                .remoteAddress(new InetSocketAddress("203.0.113.42", 12345))
                .build();
        ServerWebExchange exchange = MockServerWebExchange.from(request);

        filter.filter(exchange, chain).block();

        ArgumentCaptor<ServerWebExchange> captor = ArgumentCaptor.forClass(ServerWebExchange.class);
        verify(chain).filter(captor.capture());

        HttpHeaders headers = captor.getValue().getRequest().getHeaders();
        // Exactly one value: the real remote address, not the
        // client-supplied chain appended or preserved.
        assertThat(headers.get(ClientIpGlobalFilter.HEADER_X_CLIENT_IP)).containsExactly("203.0.113.42");
    }

    @Test
    void forwardsUnchangedWhenRemoteAddressIsUnresolvable() {
        // No remoteAddress() set on the mock request — simulates a
        // transport that doesn't expose a peer address.
        MockServerHttpRequest request = MockServerHttpRequest.get("/some/path").build();
        ServerWebExchange exchange = MockServerWebExchange.from(request);

        filter.filter(exchange, chain).block();

        verify(chain).filter(exchange);
    }
}
