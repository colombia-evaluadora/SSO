package com.co.eurekatic.notificationservice.sender;

import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.domain.RenderedNotification;
import com.co.eurekatic.notificationservice.provider.ProviderException;
import com.co.eurekatic.notificationservice.provider.ProviderRegistry;
import io.github.resilience4j.circuitbreaker.CallNotPermittedException;
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * SMS orchestrator. Iterates the
 * {@link com.co.eurekatic.notificationservice.provider.ProviderRegistry}'s
 * live roster for the channel (priority-ordered per the
 * spec), wrapping each call in the registry-provided
 * circuit breaker. The roster refreshes every 30 s (and on
 * {@code POST /actuator/providers/refresh}), so a
 * reconfiguration in the DB takes effect without restart.
 */
@Component
public class SmsSender implements NotificationSender {

    private static final Logger log = LoggerFactory.getLogger(SmsSender.class);

    private final ProviderRegistry registry;

    public SmsSender(ProviderRegistry registry) {
        this.registry = registry;
    }

    @Override
    public Channel channel() { return Channel.SMS; }

    @Override
    public String send(RenderedNotification rendered) {
        var providers = registry.providersFor(Channel.SMS);
        if (providers.isEmpty()) {
            throw new ProviderException("No SMS providers configured");
        }
        ProviderException last = null;
        for (var rp : providers) {
            CircuitBreaker breaker = rp.circuitBreaker();
            try {
                breaker.executeRunnable(() -> rp.provider().deliver(rendered));
                if (log.isDebugEnabled()) {
                    log.debug("SMS delivered via {}", rp.providerKey());
                }
                return rp.providerKey();
            } catch (CallNotPermittedException open) {
                log.warn("SMS breaker '{}' OPEN, skipping", breaker.getName());
                last = new ProviderException("Breaker open for " + breaker.getName(), open);
            } catch (ProviderException pe) {
                log.warn("SMS provider '{}' failed: {}", rp.providerKey(), pe.getMessage());
                last = pe;
            } catch (RuntimeException ex) {
                log.warn("SMS provider '{}' threw: {}", rp.providerKey(), ex.toString());
                last = new ProviderException("Provider " + rp.providerKey() + " failed", ex);
            }
        }
        throw last != null
                ? last
                : new ProviderException("All SMS providers exhausted");
    }
}