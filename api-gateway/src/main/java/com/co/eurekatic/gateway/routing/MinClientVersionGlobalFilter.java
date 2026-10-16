package com.co.eurekatic.gateway.routing;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.cloud.gateway.filter.GlobalFilter;
import org.springframework.core.Ordered;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

/**
 * {@code X-Min-Client-Version} (offline de meses, D-7): versión mínima del
 * front que el backend sigue aceptando. El front compara con su propia
 * versión de build ({@code AAAA.MM.DD-sha}, se compara por el prefijo de
 * fecha) y, después de sincronizar, pide actualizar. Vacío = no se emite:
 * todo cliente es compatible. Nunca rechaza requests: un equipo que vuelve
 * tras meses offline primero sube lo pendiente y después se actualiza.
 */
@Component
public class MinClientVersionGlobalFilter implements GlobalFilter, Ordered {

    static final String HEADER = "X-Min-Client-Version";

    private final String minVersion;

    public MinClientVersionGlobalFilter(@Value("${gateway.min-client-version:}") String minVersion) {
        this.minVersion = minVersion == null ? "" : minVersion.trim();
    }

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        if (!minVersion.isEmpty()) {
            exchange.getResponse().beforeCommit(() -> {
                exchange.getResponse().getHeaders().set(HEADER, minVersion);
                return Mono.empty();
            });
        }
        return chain.filter(exchange);
    }

    @Override
    public int getOrder() {
        return Ordered.HIGHEST_PRECEDENCE + 11;
    }
}
