package com.co.eurekatic.ssoadmin.provisioner;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.cloud.client.ServiceInstance;
import org.springframework.cloud.client.discovery.DiscoveryClient;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Locale;

/**
 * Polls the local {@link DiscoveryClient} until a fresh
 * query-service instance appears under the expected
 * service-id, or the timeout elapses.
 *
 * <p>Why this is necessary: even after the provisioner
 * returns 201 Created, the new container still has to
 * (a) finish its JVM warm-up, (b) register its Eureka
 * heartbeat, (c) get picked up by the api-gateway's
 * {@code discovery.locator}. Without this probe, the
 * controller would return before the gateway could route
 * to the new instance — first user request would 503.
 *
 * <p>The probe uses sso-admin's own
 * {@link DiscoveryClient} rather than hitting Eureka
 * directly. Spring Cloud Netflix caches the registry
 * locally with the {@code registry-fetch-interval-seconds}
 * value configured in {@code application.yml} (5s in dev);
 * that interval is the lower bound on how fast a new
 * instance becomes visible here. The probe's poll
 * interval (1s) is below that — we sleep and re-poll
 * until either the instance shows up or the overall
 * deadline fires.
 *
 * <p><b>Case folding:</b> Eureka normalizes {@code appName}
 * to UPPER CASE in its wire protocol (the {@code /apps}
 * REST response always shows e.g. {@code QUERY-SERVICE-PRUEBA}
 * — even if the registering client pushed a lowercase
 * name). Spring Cloud's {@code DiscoveryClient.getInstances}
 * does NOT paper over that normalization, so a literal
 * {@code "query-service-prueba"} lookup returns an empty
 * list. {@link #waitForInstance} tries both the caller's
 * case and the {@code toUpperCase} variant on every poll,
 * picking whichever hits first.
 */
@Component
public class EurekaReadinessProbe {

    private static final Logger log = LoggerFactory.getLogger(EurekaReadinessProbe.class);

    /** Poll interval — must be ≤ Eureka fetch interval or we'll miss heartbeats. */
    private static final Duration POLL_INTERVAL = Duration.ofSeconds(1);

    /** Total wait before giving up. Generous because the
     *  JVM warm-up window is the dominant cost in dev
     *  (the sso query-service takes ~30s to be UP). */
    private static final Duration TIMEOUT = Duration.ofSeconds(45);

    private final DiscoveryClient discoveryClient;

    public EurekaReadinessProbe(DiscoveryClient discoveryClient) {
        this.discoveryClient = discoveryClient;
    }

    /**
     * Blocks until the given service-id has at least one
     * known instance, or throws {@link ProvisioningException}
     * with {@link ProvisioningException.Code#EUREKA_TIMEOUT}.
     *
     * @param serviceId The Eureka service-id to wait for
     *                  (e.g. {@code query-service-oracle-dev}).
     */
    public void waitForInstance(String serviceId) {
        Instant deadline = Instant.now().plus(TIMEOUT);
        // Probe both cases per poll: Eureka stores app names
        // uppercase in the wire, but Spring Cloud
        // DiscoveryClient doesn't normalize a lowercase
        // lookup. Belt-and-braces until we know which arm
        // of the cache actually serves the request.
        String upper = serviceId.toUpperCase(Locale.ROOT);
        log.info("Waiting up to {} for {} (or {}) to register with Eureka",
                TIMEOUT, serviceId, upper);
        while (Instant.now().isBefore(deadline)) {
            List<ServiceInstance> instances = firstNonEmpty(
                    discoveryClient.getInstances(upper),
                    discoveryClient.getInstances(serviceId));
            if (instances != null && !instances.isEmpty()) {
                log.info("Instance {} registered (host={}, port={})",
                        serviceId,
                        instances.get(0).getHost(),
                        instances.get(0).getPort());
                return;
            }
            sleep(POLL_INTERVAL);
        }
        // No log at the throw site — the caller (and the
        // GlobalExceptionHandler) will surface it. But we
        // do want one diagnostic: confirm which exact
        // service-ids the DiscoveryClient knows about, so a
        // post-mortem doesn't have to guess whether the
        // absence is a typo, a race, or a case bug.
        log.warn("Eureka readiness timed out for {}. Known services: {}",
                serviceId, discoveryClient.getServices());
        throw new ProvisioningException(
                ProvisioningException.Code.EUREKA_TIMEOUT,
                serviceId + " did not register within " + TIMEOUT);
    }

    @SafeVarargs
    private static List<ServiceInstance> firstNonEmpty(
            List<ServiceInstance>... candidates) {
        for (List<ServiceInstance> c : candidates) {
            if (c != null && !c.isEmpty()) return c;
        }
        return java.util.Collections.emptyList();
    }

    private static void sleep(Duration d) {
        try {
            Thread.sleep(d.toMillis());
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
            throw new ProvisioningException(
                    ProvisioningException.Code.EUREKA_TIMEOUT,
                    "Readiness probe interrupted");
        }
    }
}