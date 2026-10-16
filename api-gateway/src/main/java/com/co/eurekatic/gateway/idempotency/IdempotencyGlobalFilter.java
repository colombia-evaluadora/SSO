package com.co.eurekatic.gateway.idempotency;

import com.co.eurekatic.common.security.AuthPrincipal;
import org.reactivestreams.Publisher;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.cloud.gateway.filter.GlobalFilter;
import org.springframework.core.Ordered;
import org.springframework.core.io.buffer.DataBuffer;
import org.springframework.core.io.buffer.DataBufferUtils;
import org.springframework.core.io.buffer.DefaultDataBufferFactory;
import org.springframework.data.redis.core.ReactiveStringRedisTemplate;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatusCode;
import org.springframework.http.MediaType;
import org.springframework.http.server.reactive.ServerHttpRequest;
import org.springframework.http.server.reactive.ServerHttpRequestDecorator;
import org.springframework.http.server.reactive.ServerHttpResponse;
import org.springframework.http.server.reactive.ServerHttpResponseDecorator;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.ReactiveSecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Flux;
import reactor.core.publisher.Mono;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Duration;
import java.util.HexFormat;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.atomic.AtomicReference;

/**
 * {@code Idempotency-Key} en el gateway (BE-1, escritura offline). La outbox
 * del front reenvía la misma clave en cada reintento; si la primera vez el
 * servidor aplicó el cambio pero la respuesta se perdió, el reintento recibe
 * la respuesta guardada en vez de ejecutarse otra vez.
 *
 * <ul>
 *   <li>Solo mutaciones (POST/PUT/PATCH/DELETE) autenticadas con la cabecera;
 *       la clave se particiona por {@code sub}. Multipart no entra (los
 *       soportes se suben aparte y la outbox ya guarda su {@code pk_tarchivo}).</li>
 *   <li>Misma clave con otro cuerpo → 422 {@code IDEMPOTENCY_KEY_REUSED};
 *       en curso → 409 {@code IDEMPOTENCY_IN_PROGRESS} con {@code Retry-After}.</li>
 *   <li>Se guardan las respuestas 2xx/4xx (hasta {@code max-body} bytes) con
 *       TTL ≥ la ventana de 14 días de la sesión offline; 5xx y errores liberan
 *       la clave para que el reintento vuelva a ejecutarse.</li>
 *   <li>Sin Redis, o si falla, el filtro deja pasar la petición (fail open):
 *       la idempotencia es una red de seguridad, no un requisito para escribir.</li>
 * </ul>
 */
@Component
public class IdempotencyGlobalFilter implements GlobalFilter, Ordered {

    private static final Logger log = LoggerFactory.getLogger(IdempotencyGlobalFilter.class);

    static final String HEADER = "Idempotency-Key";
    static final String REPLAYED_HEADER = "Idempotent-Replayed";
    private static final Set<HttpMethod> MUTATIONS =
            Set.of(HttpMethod.POST, HttpMethod.PUT, HttpMethod.PATCH, HttpMethod.DELETE);
    private static final int MAX_KEY_LENGTH = 128;

    private final IdempotencyStore store;
    private final Duration ttl;
    private final int maxBody;

    @Autowired
    public IdempotencyGlobalFilter(
            ObjectProvider<ReactiveStringRedisTemplate> redis,
            @Value("${gateway.idempotency.enabled:true}") boolean enabled,
            @Value("${gateway.idempotency.ttl-days:15}") long ttlDays,
            @Value("${gateway.idempotency.max-body-bytes:262144}") int maxBody) {
        ReactiveStringRedisTemplate template = enabled ? redis.getIfAvailable() : null;
        this.store = template == null ? null : new RedisIdempotencyStore(template);
        this.ttl = Duration.ofDays(ttlDays);
        this.maxBody = maxBody;
    }

    IdempotencyGlobalFilter(IdempotencyStore store, Duration ttl, int maxBody) {
        this.store = store;
        this.ttl = ttl;
        this.maxBody = maxBody;
    }

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        ServerHttpRequest request = exchange.getRequest();
        String key = request.getHeaders().getFirst(HEADER);
        MediaType contentType = request.getHeaders().getContentType();
        boolean applies = store != null
                && MUTATIONS.contains(request.getMethod())
                && key != null && !key.isBlank() && key.length() <= MAX_KEY_LENGTH
                && (contentType == null || !MediaType.MULTIPART_FORM_DATA.isCompatibleWith(contentType));
        if (!applies) {
            return chain.filter(exchange);
        }
        return currentSubject()
                .map(Optional::of)
                .defaultIfEmpty(Optional.empty())
                .flatMap(sub -> sub.isEmpty()
                        ? chain.filter(exchange)
                        : handle(exchange, chain, sub.get() + ":" + key.trim()));
    }

    private static Mono<String> currentSubject() {
        return ReactiveSecurityContextHolder.getContext()
                .map(ctx -> ctx.getAuthentication())
                .filter(Authentication::isAuthenticated)
                .map(Authentication::getPrincipal)
                .ofType(AuthPrincipal.class)
                .map(AuthPrincipal::email);
    }

    private Mono<Void> handle(ServerWebExchange exchange, GatewayFilterChain chain, String storeKey) {
        ServerHttpRequest request = exchange.getRequest();
        return DataBufferUtils.join(request.getBody())
                .map(IdempotencyGlobalFilter::drain)
                .defaultIfEmpty(new byte[0])
                .flatMap(bytes -> {
                    String hash = hash(request, bytes);
                    ServerWebExchange cached = exchange.mutate().request(withBody(request, bytes)).build();
                    return store.reserve(storeKey, StoredResponse.pending(hash), ttl)
                            .map(Optional::of)
                            .onErrorResume(e -> {
                                log.warn("Idempotency-Key sin almacén ({}): se deja pasar", e.toString());
                                return Mono.just(Optional.empty());
                            })
                            .defaultIfEmpty(Optional.empty())
                            .flatMap(reserved -> {
                                if (reserved.isEmpty()) {
                                    return chain.filter(cached);
                                }
                                return reserved.get()
                                        ? proceed(cached, chain, storeKey, hash)
                                        : existing(cached, chain, storeKey, hash);
                            });
                });
    }

    private Mono<Void> existing(ServerWebExchange exchange, GatewayFilterChain chain, String storeKey, String hash) {
        return store.get(storeKey)
                .map(Optional::of)
                .defaultIfEmpty(Optional.empty())
                .onErrorResume(e -> Mono.just(Optional.empty()))
                .flatMap(found -> {
                    if (found.isEmpty()) {
                        // Venció entre el reserve y el get: se ejecuta normal.
                        return chain.filter(exchange);
                    }
                    StoredResponse stored = found.get();
                    if (!stored.bodyHash().equals(hash)) {
                        return writeJson(exchange.getResponse(), 422, "IDEMPOTENCY_KEY_REUSED",
                                "La Idempotency-Key ya se usó con otro contenido.");
                    }
                    if (!stored.isDone()) {
                        exchange.getResponse().getHeaders().set(HttpHeaders.RETRY_AFTER, "2");
                        return writeJson(exchange.getResponse(), 409, "IDEMPOTENCY_IN_PROGRESS",
                                "Este cambio todavía se está procesando.");
                    }
                    ServerHttpResponse response = exchange.getResponse();
                    response.setStatusCode(HttpStatusCode.valueOf(stored.status()));
                    if (!stored.contentType().isEmpty()) {
                        response.getHeaders().set(HttpHeaders.CONTENT_TYPE, stored.contentType());
                    }
                    response.getHeaders().set(REPLAYED_HEADER, "true");
                    return response.writeWith(Mono.just(response.bufferFactory().wrap(stored.body())));
                });
    }

    private Mono<Void> proceed(ServerWebExchange exchange, GatewayFilterChain chain, String storeKey, String hash) {
        ServerHttpResponse original = exchange.getResponse();
        AtomicReference<byte[]> captured = new AtomicReference<>(new byte[0]);
        ServerHttpResponseDecorator decorated = new ServerHttpResponseDecorator(original) {
            @Override
            public Mono<Void> writeWith(Publisher<? extends DataBuffer> body) {
                return DataBufferUtils.join(Flux.from(body))
                        .map(IdempotencyGlobalFilter::drain)
                        .defaultIfEmpty(new byte[0])
                        .flatMap(bytes -> {
                            captured.set(bytes);
                            return super.writeWith(Mono.just(bufferFactory().wrap(bytes)));
                        });
            }

            @Override
            public Mono<Void> writeAndFlushWith(Publisher<? extends Publisher<? extends DataBuffer>> body) {
                return writeWith(Flux.from(body).flatMapSequential(p -> p));
            }
        };
        return chain.filter(exchange.mutate().response(decorated).build())
                .then(Mono.defer(() -> finish(decorated, captured.get(), storeKey, hash)))
                .onErrorResume(e -> store.release(storeKey)
                        .onErrorResume(x -> Mono.empty())
                        .then(Mono.error(e)));
    }

    private Mono<Void> finish(ServerHttpResponse response, byte[] body, String storeKey, String hash) {
        HttpStatusCode status = response.getStatusCode();
        Mono<Void> op;
        if (status == null || status.is5xxServerError() || body.length > maxBody) {
            op = store.release(storeKey);
        } else {
            MediaType type = response.getHeaders().getContentType();
            op = store.complete(storeKey,
                    StoredResponse.done(hash, status.value(), type == null ? "" : type.toString(), body), ttl);
        }
        return op.onErrorResume(e -> {
            log.warn("No se pudo guardar la respuesta idempotente: {}", e.toString());
            return Mono.empty();
        });
    }

    private static Mono<Void> writeJson(ServerHttpResponse response, int status, String code, String message) {
        response.setStatusCode(HttpStatusCode.valueOf(status));
        response.getHeaders().setContentType(MediaType.APPLICATION_JSON);
        byte[] body = ("{\"code\":\"" + code + "\",\"message\":\"" + message + "\"}").getBytes(StandardCharsets.UTF_8);
        return response.writeWith(Mono.just(response.bufferFactory().wrap(body)));
    }

    private static ServerHttpRequest withBody(ServerHttpRequest request, byte[] bytes) {
        return new ServerHttpRequestDecorator(request) {
            @Override
            public Flux<DataBuffer> getBody() {
                return Flux.defer(() -> Flux.just(DefaultDataBufferFactory.sharedInstance.wrap(bytes)));
            }
        };
    }

    private static byte[] drain(DataBuffer buffer) {
        try {
            byte[] bytes = new byte[buffer.readableByteCount()];
            buffer.read(bytes);
            return bytes;
        } finally {
            DataBufferUtils.release(buffer);
        }
    }

    private static String hash(ServerHttpRequest request, byte[] body) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            digest.update(request.getMethod().name().getBytes(StandardCharsets.UTF_8));
            digest.update(request.getURI().getRawPath().getBytes(StandardCharsets.UTF_8));
            String query = request.getURI().getRawQuery();
            if (query != null) {
                digest.update(query.getBytes(StandardCharsets.UTF_8));
            }
            digest.update(body);
            return HexFormat.of().formatHex(digest.digest());
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    @Override
    public int getOrder() {
        // Despues del JWT (contexto de seguridad) y antes del enrutado.
        return Ordered.LOWEST_PRECEDENCE - 90;
    }
}
