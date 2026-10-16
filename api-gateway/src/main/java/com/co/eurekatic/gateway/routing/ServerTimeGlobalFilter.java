package com.co.eurekatic.gateway.routing;

import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.cloud.gateway.filter.GlobalFilter;
import org.springframework.core.Ordered;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

import java.time.Clock;
import java.time.Instant;

/**
 * {@code X-Server-Time} (BE-7) en toda respuesta enrutada: hora del servidor
 * en ISO-8601 UTC. La outbox del front la usa para detectar el desfase del
 * reloj del equipo (fechas de captura offline y ventana de 14 días).
 */
@Component
public class ServerTimeGlobalFilter implements GlobalFilter, Ordered {

    static final String HEADER = "X-Server-Time";

    private final Clock clock;

    public ServerTimeGlobalFilter() {
        this(Clock.systemUTC());
    }

    ServerTimeGlobalFilter(Clock clock) {
        this.clock = clock;
    }

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        exchange.getResponse().beforeCommit(() -> {
            exchange.getResponse().getHeaders().set(HEADER, Instant.now(clock).toString());
            return Mono.empty();
        });
        return chain.filter(exchange);
    }

    @Override
    public int getOrder() {
        return Ordered.HIGHEST_PRECEDENCE + 10;
    }
}
