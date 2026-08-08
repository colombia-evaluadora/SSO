package com.co.eurekatic.gateway.openapi;

import org.springframework.http.HttpStatus;
import org.springframework.http.server.reactive.ServerHttpResponse;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import reactor.core.publisher.Mono;

import java.net.URI;

/**
 * Serves {@code GET /api/docs} — the human entry point to the API
 * documentation — by redirecting to the Swagger UI bundle, pointed at
 * this gateway's aggregated spec.
 *
 * <p><b>Why this exists instead of letting springdoc do it.</b>
 * springdoc ships a welcome controller for exactly this purpose, and
 * the natural config is {@code springdoc.swagger-ui.path=/api/docs}.
 * That configuration is broken in this application: with it set,
 * springdoc's {@code SwaggerWelcomeWebFlux} owns {@code GET /api/docs}
 * and never completes the response. The request hangs until the client
 * gives up. Measured on the deployed image — moving
 * {@code springdoc.swagger-ui.path} off {@code /api/docs} turned a hard
 * timeout into a clean 404 with no other change, which is what left
 * room for this controller.
 *
 * <p>Do not "simplify" this away by pointing
 * {@code springdoc.swagger-ui.path} back at {@code /api/docs}; that
 * reintroduces the hang. See the comments in application.yml.
 *
 * <p>The redirect target is springdoc's default webjars location.
 * {@code springdoc.webjars.prefix} is not honored by springdoc-webflux
 * here (measured: the prefixed path 404s, the default path serves the
 * bundle), so the literal {@code /webjars/...} path is the correct and
 * only working one. {@code GatewaySecurityConfig} already permitAlls
 * both {@code /api/docs/**} and {@code /webjars/**}, so the redirect
 * and the assets are reachable unauthenticated — the docs are a public
 * surface by design.
 */
@RestController
public class SwaggerUiRedirectController {

    /**
     * Our own Swagger UI page
     * ({@code src/main/resources/static/api/docs/ui/index.html}), not
     * the webjar's.
     *
     * <p>Do NOT point this at {@code /webjars/swagger-ui/index.html}.
     * That file loads the webjar's stock {@code swagger-initializer.js},
     * whose spec URL is hardcoded to
     * {@code https://petstore.swagger.io/v2/swagger.json} — it renders
     * the Petstore demo instead of this platform's API. Appending
     * {@code ?configUrl=...} does not help: the stock initializer never
     * reads query parameters. (springdoc normally rewrites that file
     * through its SwaggerIndexPageTransformer, but this gateway
     * deliberately bypasses springdoc's UI flow because it hangs.)
     *
     * <p>Our page loads the same webjar assets and calls
     * {@code SwaggerUIBundle} itself against the aggregated spec.
     */
    private static final URI SWAGGER_UI = URI.create("/api/docs/ui/index.html");

    /**
     * Both {@code /api/docs} and {@code /api/docs/} are mapped: the
     * trailing-slash form is not matched implicitly here, and a
     * visitor typing the URL by hand can produce either. Without the
     * second mapping the slash variant falls through to the gateway's
     * deny-by-default and 404s.
     */
    @GetMapping({"/api/docs", "/api/docs/"})
    public Mono<Void> redirectToSwaggerUi(ServerHttpResponse response) {
        // 302 rather than 301: the docs entry point is a convenience
        // alias, and a permanent redirect would get baked into browser
        // caches, making any future move of the UI bundle painful to
        // roll out.
        response.setStatusCode(HttpStatus.FOUND);
        response.getHeaders().setLocation(SWAGGER_UI);
        return response.setComplete();
    }
}
