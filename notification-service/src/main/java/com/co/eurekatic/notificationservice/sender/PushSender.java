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
 * PUSH orchestrator — same shape as {@link SmsSender}.
 */
@Component
public class PushSender implements NotificationSender {

    private static final Logger log = LoggerFactory.getLogger(PushSender.class);

    private final ProviderRegistry registry;

    public PushSender(ProviderRegistry registry) {
        this.registry = registry;
    }

    @Override
    public Channel channel() { return Channel.PUSH; }

    @Override
    public String send(RenderedNotification rendered) {
        var providers = registry.providersFor(Channel.PUSH);
        if (providers.isEmpty()) {
            throw new ProviderException("No PUSH providers configured");
        }
        ProviderException last = null;
        for (var rp : providers) {
            CircuitBreaker breaker = rp.circuitBreaker();
            try {
                breaker.executeRunnable(() -> rp.provider().deliver(rendered));
                if (log.isDebugEnabled()) {
                    log.debug("Push delivered via {}", rp.providerKey());
                }
                return rp.providerKey();
            } catch (CallNotPermittedException open) {
                log.warn("Push breaker '{}' OPEN, skipping", breaker.getName());
                last = new ProviderException("Breaker open for " + breaker.getName(), open);
            } catch (ProviderException pe) {
                log.warn("Push provider '{}' failed: {}", rp.providerKey(), pe.getMessage());
                last = pe;
            } catch (RuntimeException ex) {
                log.warn("Push provider '{}' threw: {}", rp.providerKey(), ex.toString());
                last = new ProviderException("Provider " + rp.providerKey() + " failed", ex);
            }
        }
        throw last != null
                ? last
                : new ProviderException("All PUSH providers exhausted");
    }
}