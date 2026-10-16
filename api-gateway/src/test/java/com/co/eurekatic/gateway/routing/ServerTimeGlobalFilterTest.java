package com.co.eurekatic.gateway.routing;

import org.junit.jupiter.api.Test;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.web.server.MockServerWebExchange;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;

import static org.assertj.core.api.Assertions.assertThat;

class ServerTimeGlobalFilterTest {

    @Test
    void addsServerTimeHeaderInIsoUtc() {
        var clock = Clock.fixed(Instant.parse("2026-10-15T12:00:00Z"), ZoneOffset.UTC);
        var filter = new ServerTimeGlobalFilter(clock);
        var exchange = MockServerWebExchange.from(MockServerHttpRequest.get("/api/eval-col/health"));
        GatewayFilterChain chain = ex -> ex.getResponse().setComplete();

        filter.filter(exchange, chain).block(Duration.ofSeconds(5));

        assertThat(exchange.getResponse().getHeaders().getFirst(ServerTimeGlobalFilter.HEADER))
                .isEqualTo("2026-10-15T12:00:00Z");
    }
}
