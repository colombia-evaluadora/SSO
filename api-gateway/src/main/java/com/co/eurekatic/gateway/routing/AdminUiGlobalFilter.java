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
import org.springframework.http.MediaType;
import org.springframework.http.server.reactive.ServerHttpResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import org.springframework.web.server.WebFilter;
import org.springframework.web.server.WebFilterChain;
import reactor.core.publisher.Flux;
import reactor.core.publisher.Mono;

import java.io.IOException;

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
        log.info("AdminUiGlobalFilter saw path={}", path);
        if (!path.equals(ADMIN_PREFIX) && !path.startsWith(ADMIN_PREFIX + "/")) {
            return chain.filter(exchange);
        }

        String resourcePath;
        MediaType mediaType;
        if (path.startsWith(ASSETS_PREFIX)) {
            resourcePath = "static/admin/assets/" + path.substring(ASSETS_PREFIX.length());
            mediaType = mediaTypeFor(resourcePath);
        } else {
            resourcePath = "static/admin/index.html";
            mediaType = MediaType.TEXT_HTML;
        }

        Resource resource = new ClassPathResource(resourcePath);
        if (!resource.exists()) {
            log.warn("Admin UI resource missing on classpath: {}", resourcePath);
            return chain.filter(exchange);
        }

        ServerHttpResponse response = exchange.getResponse();
        response.setStatusCode(org.springframework.http.HttpStatus.OK);
        response.getHeaders().set(HttpHeaders.CONTENT_TYPE, mediaType.toString());
        response.getHeaders().set(HttpHeaders.CACHE_CONTROL, "no-cache");
        try {
            byte[] bytes = resource.getInputStream().readAllBytes();
            DataBuffer buffer = response.bufferFactory().wrap(bytes);
            return response.writeWith(Flux.just(buffer))
                    .doOnError(e -> DataBufferUtils.release(buffer));
        } catch (IOException e) {
            log.error("Failed to read admin-ui resource {}", resourcePath, e);
            return Mono.error(e);
        }
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