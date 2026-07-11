package com.co.eurekatic.notificationservice.web;

import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.provider.ProviderRegistry;
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import org.springframework.boot.actuate.endpoint.annotation.Endpoint;
import org.springframework.boot.actuate.endpoint.annotation.ReadOperation;
import org.springframework.boot.actuate.endpoint.annotation.WriteOperation;
import org.springframework.stereotype.Component;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

/**
 * Custom actuator endpoint under {@code /actuator/providers}.
 *
 * <ul>
 *   <li>{@code GET /actuator/providers} → live roster:
 *       per-channel list of providers with their priority,
 *       weight, circuit-breaker state and last result.</li>
 *   <li>{@code POST /actuator/providers/refresh} →
 *       synchronously re-reads {@code provider_config} and
 *       returns the new roster. Returns 200 with the new
 *       state, or 500 if the refresh threw.</li>
 * </ul>
 *
 * <p>Mounted via {@link Endpoint @Endpoint(id = "providers")}
 * — exposed automatically once {@code providers} is added to
 * {@code management.endpoints.web.exposure.include}.
 */
@Component
@Endpoint(id = "providers")
public class ProvidersEndpoint {

    private final ProviderRegistry registry;

    public ProvidersEndpoint(ProviderRegistry registry) {
        this.registry = registry;
    }

    @ReadOperation
    public Map<String, Object> list() {
        Map<String, Object> root = new LinkedHashMap<>();
        root.put("lastLoadedAt", registry.lastLoadedAt().toString());
        Map<String, List<Map<String, Object>>> perChannel = new LinkedHashMap<>();
        for (Channel channel : Channel.values()) {
            List<ProviderRegistry.RegisteredProvider> list = registry.providersFor(channel);
            perChannel.put(channel.name(), list.stream().map(this::render).toList());
        }
        root.put("channels", perChannel);
        return root;
    }

    @WriteOperation
    public Map<String, Object> refresh() {
        registry.refresh();
        return list();
    }

    private Map<String, Object> render(ProviderRegistry.RegisteredProvider rp) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("providerKey", rp.providerKey());
        m.put("impl", rp.row().impl());
        m.put("priority", rp.row().priority());
        m.put("weight", rp.row().weight());
        m.put("policy", rp.row().policy());
        CircuitBreaker.State state = rp.circuitBreaker().getState();
        m.put("breakerState", state.name());
        CircuitBreaker.Metrics metrics = rp.circuitBreaker().getMetrics();
        m.put("breakerMetrics", Map.of(
                "successfulCalls", metrics.getNumberOfSuccessfulCalls(),
                "failedCalls", metrics.getNumberOfFailedCalls(),
                "slowCalls", metrics.getNumberOfSlowCalls(),
                "notPermittedCalls", metrics.getNumberOfNotPermittedCalls()
        ));
        m.put("settingsKeys", rp.row().settings() == null
                ? List.of()
                : rp.row().settings().keySet().stream().sorted().collect(Collectors.toList()));
        return m;
    }
}