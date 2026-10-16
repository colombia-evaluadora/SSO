package com.co.eurekatic.gateway.routing;

import org.junit.jupiter.api.Test;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.web.server.MockServerWebExchange;

import java.time.Duration;

import static org.assertj.core.api.Assertions.assertThat;

class MinClientVersionGlobalFilterTest {

    private static String run(String configured) {
        var filter = new MinClientVersionGlobalFilter(configured);
        var exchange = MockServerWebExchange.from(MockServerHttpRequest.get("/api/eval-col/health"));
        GatewayFilterChain chain = ex -> ex.getResponse().setComplete();
        filter.filter(exchange, chain).block(Duration.ofSeconds(5));
        return exchange.getResponse().getHeaders().getFirst(MinClientVersionGlobalFilter.HEADER);
    }

    @Test
    void emitsConfiguredMinimum() {
        assertThat(run("2026.10.01")).isEqualTo("2026.10.01");
    }

    @Test
    void omitsHeaderWhenNotConfigured() {
        assertThat(run("")).isNull();
    }
}
