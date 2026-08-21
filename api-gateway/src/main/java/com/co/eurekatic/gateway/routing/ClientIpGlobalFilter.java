package com.co.eurekatic.gateway.routing;

import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.cloud.gateway.filter.GlobalFilter;
import org.springframework.core.Ordered;
import org.springframework.http.server.reactive.ServerHttpRequest;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

import java.net.InetSocketAddress;

/**
 * V-audit-ctx-2 — sets {@code X-Client-Ip} to the gateway's own view of
 * the caller's IP, on every request, before it reaches the routing
 * filter.
 *
 * <p>A custom header, deliberately NOT {@code X-Forwarded-For}: Spring
 * Cloud Gateway 5's {@code NettyRoutingFilter} silently strips {@code
 * X-Forwarded-For} (and the other RFC 7239 {@code Forwarded}/{@code
 * X-Forwarded-*} headers) before proxying — confirmed empirically, this
 * filter WAS setting it correctly but query-service always saw {@code
 * null}, while an arbitrary header name set the exact same way survived
 * intact. Rather than fight SCG's built-in (and undocumented in this
 * app) forwarded-header handling, we use a name it has no opinion
 * about.
 *
 * <p>Same trust-boundary reasoning as {@link
 * UserForwardingGlobalFilter}'s {@code X-Authenticated-*} headers: any
 * header a client sends directly is spoofable, so this OVERWRITES
 * whatever the caller sent (does not append/trust it) — downstream
 * services (query-service's {@code injectRequestParams()}, which feeds
 * ClickHouse's {@code client_ip} audit column) must only ever see the
 * value the gateway itself computed from the real TCP connection. A
 * non-{@code Forwarded}-family header name is actually a small security
 * plus here too: no caller has any expectation that {@code X-Client-Ip}
 * is a trusted convention, unlike {@code X-Forwarded-For}.
 *
 * <p>Runs at the highest precedence (before auth, before routing) so
 * every request gets it, authenticated or not — same reasoning as
 * {@code injectRequestParams()} on the query-service side treating
 * IP/path as transport data, not identity data.
 */
@Component
public class ClientIpGlobalFilter implements GlobalFilter, Ordered {

    static final String HEADER_X_CLIENT_IP = "X-Client-Ip";

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        InetSocketAddress remote = exchange.getRequest().getRemoteAddress();
        if (remote == null || remote.getAddress() == null) {
            // No resolvable peer (unit tests, some local transports) —
            // forward as-is; downstream falls back to its own
            // getRemoteAddr(), same as before this filter existed.
            return chain.filter(exchange);
        }
        String ip = remote.getAddress().getHostAddress();

        ServerHttpRequest mutatedRequest = exchange.getRequest().mutate()
                .headers(h -> h.set(HEADER_X_CLIENT_IP, ip))
                .build();

        return chain.filter(exchange.mutate().request(mutatedRequest).build());
    }

    @Override
    public int getOrder() {
        // Highest precedence: must run before routing forwards the
        // request downstream, and there's no reason to wait for auth
        // — IP is transport data available for anonymous requests too.
        return Ordered.HIGHEST_PRECEDENCE;
    }
}
