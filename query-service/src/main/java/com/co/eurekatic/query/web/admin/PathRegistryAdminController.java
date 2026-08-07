package com.co.eurekatic.query.web.admin;

import com.co.eurekatic.query.routing.QueryPathRegistry;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import java.security.MessageDigest;
import java.nio.charset.StandardCharsets;
import java.util.Map;

/**
 * V33 — admin endpoint that lets sso-admin trigger an
 * immediate path-registry refresh after a catalog mutation.
 *
 * <p>The registry already auto-refreshes every
 * {@code query.path-registry.refresh-ms} (default 60s); this
 * endpoint shaves that latency to ~0 for the moment a write
 * happens.
 *
 * <p><b>Security.</b> {@code SecurityConfig} permits
 * {@code /internal/**} because the caller is sso-admin acting
 * on its own behalf — it has no user JWT to present. The
 * authentication is the shared {@code X-Internal-Token}
 * header, verified HERE (query-service has no equivalent of
 * sso-admin's {@code InternalTokenFilter}; adding a whole
 * filter for one endpoint isn't worth it).
 *
 * <p>Comparison is constant-time via
 * {@link MessageDigest#isEqual(byte[], byte[])}. When
 * {@code query.catalog.internal-token} is unset the endpoint
 * refuses every call — same fail-closed posture as the
 * {@code CatalogClient}, so a half-configured deployment
 * can't be poked from the network.
 */
@RestController
@RequestMapping("/internal/path-registry")
public class PathRegistryAdminController {

    private final QueryPathRegistry registry;
    private final byte[] expectedToken;

    public PathRegistryAdminController(
            QueryPathRegistry registry,
            @Value("${query.catalog.internal-token:}") String internalToken) {
        this.registry = registry;
        this.expectedToken = (internalToken == null ? "" : internalToken)
                .getBytes(StandardCharsets.UTF_8);
    }

    /**
     * Force-refresh the registry. Returns the new size so the
     * caller can confirm the refresh loaded something (or
     * zero, if the catalog has no path templates).
     */
    @PostMapping("/invalidate")
    public Map<String, Object> invalidate(
            @RequestHeader(value = "X-Internal-Token", required = false) String token) {
        requireInternalToken(token);
        return Map.of("size", registry.invalidate());
    }

    private void requireInternalToken(String presented) {
        if (expectedToken.length == 0) {
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE,
                    "query.catalog.internal-token is not configured on this instance");
        }
        if (presented == null || presented.isBlank()) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED,
                    "X-Internal-Token header is required");
        }
        if (!MessageDigest.isEqual(presented.getBytes(StandardCharsets.UTF_8), expectedToken)) {
            throw new ResponseStatusException(HttpStatus.UNAUTHORIZED,
                    "X-Internal-Token is invalid");
        }
    }
}
