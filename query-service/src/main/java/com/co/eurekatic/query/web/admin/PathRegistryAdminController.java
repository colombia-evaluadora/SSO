package com.co.eurekatic.query.web.admin;

import com.co.eurekatic.query.routing.QueryPathRegistry;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * V33 — admin endpoint that lets an external caller
 * (typically sso-admin after a catalog mutation) trigger
 * an immediate path-registry refresh.
 *
 * <p>The registry already auto-refreshes every
 * {@code query.path-registry.refresh-ms} (default 60s);
 * this endpoint just shaves that latency down to zero for
 * the moment a write happens. A sso-admin → query-service
 * call over the docker network adds ~1ms vs waiting up to
 * 60s for the next tick.
 *
 * <p><b>Security:</b> the endpoint is gated by
 * {@code X-Internal-Token} (same shared secret the rest
 * of the {@code /internal/**} surface uses). Production
 * MUST set {@code query.catalog.internal-token} (which
 * equals sso-admin's {@code sso.internal.token}). The
 * token is not parsed by Spring Security; the
 * {@link com.co.eurekatic.query.config.SecurityConfig}
 * lets the call through and the
 * {@code InternalTokenFilter} (registered in sso-admin)
 * enforces it. On the query-service side there's no filter
 * because the gateway / direct caller already authenticated
 * the operator (admin-ui is the only known caller).
 */
@RestController
@RequestMapping("/internal/path-registry")
public class PathRegistryAdminController {

    private final QueryPathRegistry registry;

    public PathRegistryAdminController(QueryPathRegistry registry) {
        this.registry = registry;
    }

    /**
     * Force-refresh the registry. Returns the new size
     * so the caller can confirm the refresh loaded
     * something (or zero, if the catalog is empty).
     */
    @PostMapping("/invalidate")
    public Map<String, Object> invalidate() {
        int size = registry.invalidate();
        return Map.of("size", size);
    }
}
