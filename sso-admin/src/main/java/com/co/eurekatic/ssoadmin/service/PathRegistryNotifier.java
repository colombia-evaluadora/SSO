package com.co.eurekatic.ssoadmin.service;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpHeaders;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;

import java.util.Map;

/**
 * V33 — best-effort notifier that pushes a
 * "your path-registry is stale" signal to every
 * query-service instance when a catalog mutation lands.
 *
 * <p>Why not a fan-out via RabbitMQ: the only consumer
 * is query-service (a few instances behind Eureka), and
 * we don't have a guaranteed-delivery requirement — the
 * next periodic refresh (60s) catches anything the
 * invalidate call missed. HTTP fan-out from a single
 * service is the simplest tool that fits.
 *
 * <p>Failure mode is graceful: every call is wrapped in
 * try/catch with a WARN log. A failed invalidate call
 * is not an error to the user — the admin-ui save
 * succeeds, the change lands in Postgres, and the next
 * periodic refresh on each query-service picks it up.
 * This matters because we don't want a flaky
 * query-service to break the admin's create-query flow.
 *
 * <p>The query-service URL is operator-configured via
 * {@code query-service.base-url} (default
 * {@code http://query-service:8080} in compose).
 * Production overrides with the actual service DNS.
 */
@Component
public class PathRegistryNotifier {

    private static final Logger log = LoggerFactory.getLogger(PathRegistryNotifier.class);

    private final RestClient client;
    private final String internalToken;
    private final String baseUrl;

    public PathRegistryNotifier(
            @Value("${query-service.base-url:http://query-service:8080}") String baseUrl,
            @Value("${sso.internal.token:}") String internalToken) {
        this.baseUrl = baseUrl;
        this.internalToken = internalToken;
        this.client = RestClient.builder().baseUrl(baseUrl).build();
    }

    /**
     * Ask the query-service to refresh its in-memory
     * path-registry NOW. Best-effort: a 4xx/5xx/network
     * error is logged at WARN and swallowed; the caller
     * (a successful catalog mutation) is not affected.
     */
    public void invalidate() {
        if (internalToken == null || internalToken.isBlank()) {
            // Same fail-closed posture as InternalTokenFilter
            // in sso-admin: empty token means the operator
            // hasn't configured the secret. We log + skip
            // rather than firing requests without auth.
            log.warn("PathRegistryNotifier: sso.internal.token is empty; "
                    + "skipping invalidate call to {}. The path-registry "
                    + "will catch up on the next periodic refresh (60s).",
                    baseUrl);
            return;
        }
        try {
            @SuppressWarnings("unchecked")
            Map<String, Object> body = client.post()
                    .uri("/internal/path-registry/invalidate")
                    .header(HttpHeaders.AUTHORIZATION, "")  // not used
                    .header("X-Internal-Token", internalToken)
                    .retrieve()
                    .onStatus(s -> true, (req, res) -> { /* swallow all */ })
                    .body(Map.class);
            log.info("Path-registry invalidated on {} (size={})",
                    baseUrl, body == null ? "?" : body.get("size"));
        } catch (Exception e) {
            // Best-effort. The next periodic refresh
            // (60s) is the safety net. Logged at WARN,
            // not ERROR, so the operator's error budget
            // doesn't burn on a transient outage.
            log.warn("Path-registry invalidate to {} failed (next periodic "
                    + "refresh will pick up the change): {}", baseUrl, e.getMessage());
        }
    }
}
