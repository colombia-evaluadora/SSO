package com.co.eurekatic.gateway.routing;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.core.io.ClassPathResource;
import org.springframework.core.io.Resource;
import org.springframework.core.io.buffer.DataBuffer;
import org.springframework.core.io.buffer.DataBufferUtils;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.server.reactive.ServerHttpResponse;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;
import org.springframework.web.server.ServerWebExchange;
import org.springframework.web.server.WebFilter;
import org.springframework.web.server.WebFilterChain;
import reactor.core.publisher.Flux;
import reactor.core.publisher.Mono;

import java.io.IOException;
import java.io.InputStream;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Serves the admin-ui SPA at {@code /admin/**} BEFORE Spring Cloud
 * Gateway's normal flow runs.
 *
 * <p>Why this is a {@link WebFilter}, not a {@code RouterFunction} or a
 * SCG route:
 * <ul>
 *   <li>A {@code RouterFunction} needs {@code DispatcherHandler}. SCG
 *       replaces that with {@code FilteringWebHandler}, so the router
 *       never fires.</li>
 *   <li>A SCG route forwards to a downstream URI; it can't serve a
 *       classpath resource.</li>
 *   <li>A {@link WebFilter} at the highest precedence runs before the
 *       security chain, before the route handler, and can write
 *       directly to the response.</li>
 * </ul>
 *
 * <p>Routing rules:
 * <ul>
 *   <li>{@code /admin/assets/{path}} → classpath
 *       {@code static/admin/assets/{path}} with an inferred
 *       {@code Content-Type}.</li>
 *   <li>Anything else under {@code /admin/**} → classpath
 *       {@code static/admin/index.html} (SPA history-mode fallback).</li>
 * </ul>
 *
 * <p>Caching: Vite emits content-hashed names under {@code /admin/assets/},
 * so those are served {@code immutable} for a year; {@code index.html}
 * (and the rest) stays {@code no-cache} so a deploy is picked up at once.
 * Bytes already read are kept in memory (bounded) to avoid re-reading the
 * classpath on every request. An asset suffix with {@code ..}, a backslash or a percent sign (double encoding),
 * or one that normalizes out of {@code static/admin/assets/}, is a 404.
 *
 * <p>The SPA is public on purpose: the JWT lives in the React app's
 * memory, not the URL. Deep-link auth is enforced by the SPA's
 * {@code RequireAuth} wrapper and the downstream API endpoints
 * ({@code /sso-admin/**}, {@code /auth/refresh}).
 */
@Component
@Order(Ordered.HIGHEST_PRECEDENCE)
public class AdminUiGlobalFilter implements WebFilter, Ordered {

    private static final Logger log = LoggerFactory.getLogger(AdminUiGlobalFilter.class);
    private static final String ADMIN_PREFIX = "/admin";
    private static final String ASSETS_PREFIX = "/admin/assets/";
    private static final String ASSETS_DIR = "static/admin/assets/";
    private static final String INDEX_RESOURCE = "static/admin/index.html";
    private static final String IMMUTABLE_CACHE = "public, max-age=31536000, immutable";
    /** Upper bound on cached resources (the SPA has far fewer files). */
    private static final int MAX_CACHED_RESOURCES = 512;

    private final Map<String, byte[]> cache = new ConcurrentHashMap<>();

    public AdminUiGlobalFilter() {
        log.info("AdminUiGlobalFilter instantiated — will serve SPA at /admin/**");
    }

    /** Run before everything else — before Spring Security's chain
     *  and before SCG's {@code RoutePredicateHandlerMapping}. */
    @Override
    public int getOrder() {
        return Ordered.HIGHEST_PRECEDENCE;
    }

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, WebFilterChain chain) {
        String path = exchange.getRequest().getPath().value();
        log.debug("AdminUiGlobalFilter saw path={}", path);
        if (!path.equals(ADMIN_PREFIX) && !path.startsWith(ADMIN_PREFIX + "/")) {
            return chain.filter(exchange);
        }

        String resourcePath;
        MediaType mediaType;
        String cacheControl;
        if (path.startsWith(ASSETS_PREFIX)) {
            resourcePath = safeAssetPath(exchange.getRequest().getURI().getPath());
            if (resourcePath == null) {
                exchange.getResponse().setStatusCode(HttpStatus.NOT_FOUND);
                return exchange.getResponse().setComplete();
            }
            mediaType = mediaTypeFor(resourcePath);
            cacheControl = IMMUTABLE_CACHE;
        } else {
            resourcePath = INDEX_RESOURCE;
            mediaType = MediaType.TEXT_HTML;
            cacheControl = "no-cache";
        }

        byte[] bytes;
        try {
            bytes = load(resourcePath);
        } catch (IOException e) {
            log.error("Failed to read admin-ui resource {}", resourcePath, e);
            return Mono.error(e);
        }
        if (bytes == null) {
            log.warn("Admin UI resource missing on classpath: {}", resourcePath);
            return chain.filter(exchange);
        }

        ServerHttpResponse response = exchange.getResponse();
        response.setStatusCode(HttpStatus.OK);
        response.getHeaders().set(HttpHeaders.CONTENT_TYPE, mediaType.toString());
        response.getHeaders().set(HttpHeaders.CACHE_CONTROL, cacheControl);
        DataBuffer buffer = response.bufferFactory().wrap(bytes);
        return response.writeWith(Flux.just(buffer))
                .doOnError(e -> DataBufferUtils.release(buffer));
    }

    /** Cached classpath read; null when the resource does not exist. */
    private byte[] load(String resourcePath) throws IOException {
        byte[] cached = cache.get(resourcePath);
        if (cached != null) {
            return cached;
        }
        Resource resource = new ClassPathResource(resourcePath);
        if (!resource.exists()) {
            return null;
        }
        byte[] bytes;
        try (InputStream in = resource.getInputStream()) {
            bytes = in.readAllBytes();
        }
        if (cache.size() < MAX_CACHED_RESOURCES) {
            cache.put(resourcePath, bytes);
        }
        return bytes;
    }

    /**
     * Maps a decoded request path under {@code /admin/assets/} to a classpath
     * location, or null if the suffix is empty, contains {@code ..}, a
     * backslash or a NUL, or leaves {@code static/admin/assets/} once normalized.
     */
    static String safeAssetPath(String decodedPath) {
        if (decodedPath == null || !decodedPath.startsWith(ASSETS_PREFIX)) {
            return null;
        }
        String suffix = decodedPath.substring(ASSETS_PREFIX.length());
        if (suffix.isEmpty() || suffix.contains("..") || suffix.contains("\\")
                || suffix.indexOf('\0') >= 0 || suffix.contains("%") ||suffix.startsWith("/")) {
            return null;
        }
        String normalized = StringUtils.cleanPath(ASSETS_DIR + suffix);
        if (!normalized.startsWith(ASSETS_DIR) || normalized.equals(ASSETS_DIR)) {
            return null;
        }
        return normalized;
    }

    private static MediaType mediaTypeFor(String path) {
        if (path.endsWith(".js") || path.endsWith(".mjs")) return MediaType.valueOf("application/javascript");
        if (path.endsWith(".css")) return MediaType.valueOf("text/css");
        if (path.endsWith(".json")) return MediaType.APPLICATION_JSON;
        if (path.endsWith(".svg")) return MediaType.valueOf("image/svg+xml");
        if (path.endsWith(".png")) return MediaType.IMAGE_PNG;
        if (path.endsWith(".ico")) return MediaType.valueOf("image/x-icon");
        if (path.endsWith(".woff2")) return MediaType.valueOf("font/woff2");
        if (path.endsWith(".woff")) return MediaType.valueOf("font/woff");
        return MediaType.APPLICATION_OCTET_STREAM;
    }
}