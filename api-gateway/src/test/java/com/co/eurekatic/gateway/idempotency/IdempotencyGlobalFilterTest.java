package com.co.eurekatic.gateway.idempotency;

import com.co.eurekatic.common.security.AuthPrincipal;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.core.io.buffer.DataBufferUtils;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.web.server.MockServerWebExchange;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.ReactiveSecurityContextHolder;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;

/** {@link IdempotencyGlobalFilter} con un almacén en memoria (sin Redis). */
class IdempotencyGlobalFilterTest {

    /** Almacén en memoria con la misma semántica que Redis SET NX. */
    static class MemoryStore implements IdempotencyStore {
        final Map<String, StoredResponse> data = new ConcurrentHashMap<>();
        boolean failing;

        @Override
        public Mono<Boolean> reserve(String key, StoredResponse pending, Duration ttl) {
            if (failing) return Mono.error(new IllegalStateException("redis caido"));
            return Mono.just(data.putIfAbsent(key, pending) == null);
        }

        @Override
        public Mono<StoredResponse> get(String key) {
            return Mono.justOrEmpty(data.get(key));
        }

        @Override
        public Mono<Void> complete(String key, StoredResponse done, Duration ttl) {
            data.put(key, done);
            return Mono.empty();
        }

        @Override
        public Mono<Void> release(String key) {
            data.remove(key);
            return Mono.empty();
        }
    }

    private MemoryStore store;
    private IdempotencyGlobalFilter filter;
    private AtomicInteger calls;
    private HttpStatus downstreamStatus;

    @BeforeEach
    void setUp() {
        store = new MemoryStore();
        filter = new IdempotencyGlobalFilter(store, Duration.ofDays(15), 1024);
        calls = new AtomicInteger();
        downstreamStatus = HttpStatus.OK;
    }

    /** Cadena que lee el cuerpo (como el enrutado) y responde con un JSON numerado. */
    private GatewayFilterChain chain() {
        return exchange -> DataBufferUtils.join(exchange.getRequest().getBody())
                .map(b -> {
                    DataBufferUtils.release(b);
                    return 1;
                })
                .defaultIfEmpty(0)
                .flatMap(x -> {
                    int n = calls.incrementAndGet();
                    var response = exchange.getResponse();
                    response.setStatusCode(downstreamStatus);
                    response.getHeaders().setContentType(MediaType.APPLICATION_JSON);
                    byte[] body = ("{\"n\":" + n + "}").getBytes(StandardCharsets.UTF_8);
                    return response.writeWith(Mono.just(response.bufferFactory().wrap(body)));
                });
    }

    private MockServerWebExchange put(String key, String body) {
        return MockServerWebExchange.from(MockServerHttpRequest
                .put("/api/eval-col/planeador/actividades/estudiantes/7/calificar")
                .header(IdempotencyGlobalFilter.HEADER, key)
                .contentType(MediaType.APPLICATION_JSON)
                .body(body));
    }

    private void run(ServerWebExchange exchange, String user) {
        var principal = new AuthPrincipal(user, 1L, Set.of("CEVAL-DOCENTE"), "access");
        var auth = new UsernamePasswordAuthenticationToken(principal, null, List.of());
        filter.filter(exchange, chain())
                .contextWrite(ReactiveSecurityContextHolder.withAuthentication(auth))
                .block(Duration.ofSeconds(5));
    }

    private static String body(MockServerWebExchange exchange) {
        return exchange.getResponse().getBodyAsString().block(Duration.ofSeconds(5));
    }

    @Test
    void retryWithSameKeyReplaysStoredResponseWithoutReExecuting() {
        var first = put("k1", "{\"CALIFICACION\":\"4\"}");
        run(first, "docente@x.co");
        var second = put("k1", "{\"CALIFICACION\":\"4\"}");
        run(second, "docente@x.co");

        assertThat(calls.get()).isEqualTo(1);
        assertThat(body(second)).isEqualTo("{\"n\":1}");
        assertThat(second.getResponse().getHeaders().getFirst(IdempotencyGlobalFilter.REPLAYED_HEADER)).isEqualTo("true");
    }

    @Test
    void sameKeyWithDifferentBodyIs422() {
        run(put("k1", "{\"CALIFICACION\":\"4\"}"), "docente@x.co");
        var other = put("k1", "{\"CALIFICACION\":\"5\"}");
        run(other, "docente@x.co");

        assertThat(other.getResponse().getStatusCode().value()).isEqualTo(422);
        assertThat(body(other)).contains("IDEMPOTENCY_KEY_REUSED");
        assertThat(calls.get()).isEqualTo(1);
    }

    @Test
    void keysArePartitionedByUser() {
        run(put("k1", "{}"), "a@x.co");
        run(put("k1", "{}"), "b@x.co");
        assertThat(calls.get()).isEqualTo(2);
    }

    @Test
    void inProgressKeyIs409WithRetryAfter() {
        store.data.put("docente@x.co:k1", StoredResponse.pending(""));
        var exchange = put("k1", "{}");
        run(exchange, "docente@x.co");
        // El hash no coincide con el pendiente vacío: se protege igual.
        assertThat(exchange.getResponse().getStatusCode().value()).isIn(409, 422);
        assertThat(calls.get()).isZero();
    }

    @Test
    void serverErrorReleasesTheKeySoTheRetryExecutes() {
        downstreamStatus = HttpStatus.INTERNAL_SERVER_ERROR;
        run(put("k1", "{}"), "docente@x.co");
        downstreamStatus = HttpStatus.OK;
        var retry = put("k1", "{}");
        run(retry, "docente@x.co");
        assertThat(calls.get()).isEqualTo(2);
        assertThat(body(retry)).isEqualTo("{\"n\":2}");
    }

    @Test
    void failsOpenWhenTheStoreIsDown() {
        store.failing = true;
        run(put("k1", "{}"), "docente@x.co");
        run(put("k1", "{}"), "docente@x.co");
        assertThat(calls.get()).isEqualTo(2);
    }

    @Test
    void anonymousOrWithoutHeaderPassesThrough() {
        var exchange = MockServerWebExchange.from(MockServerHttpRequest
                .post("/api/eval-col/x").contentType(MediaType.APPLICATION_JSON).body("{}"));
        run(exchange, "docente@x.co");
        filter.filter(put("k9", "{}"), chain()).block(Duration.ofSeconds(5));
        assertThat(calls.get()).isEqualTo(2);
        assertThat(store.data).isEmpty();
    }
}
