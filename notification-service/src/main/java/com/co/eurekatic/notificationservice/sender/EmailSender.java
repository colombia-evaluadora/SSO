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
 * EMAIL orchestrator — same shape as {@link SmsSender}.
 */
@Component
public class EmailSender implements NotificationSender {

    private static final Logger log = LoggerFactory.getLogger(EmailSender.class);

    private final ProviderRegistry registry;

    public EmailSender(ProviderRegistry registry) {
        this.registry = registry;
    }

    @Override
    public Channel channel() { return Channel.EMAIL; }

    @Override
    public String send(RenderedNotification rendered) {
        var providers = registry.providersFor(Channel.EMAIL);
        if (providers.isEmpty()) {
            throw new ProviderException("No EMAIL providers configured");
        }
        ProviderException last = null;
        for (var rp : providers) {
            CircuitBreaker breaker = rp.circuitBreaker();
            try {
                breaker.executeRunnable(() -> rp.provider().deliver(rendered));
                if (log.isDebugEnabled()) {
                    log.debug("Email delivered via {}", rp.providerKey());
                }
                return rp.providerKey();
            } catch (CallNotPermittedException open) {
                log.warn("Email breaker '{}' OPEN, skipping", breaker.getName());
                last = new ProviderException("Breaker open for " + breaker.getName(), open);
            } catch (ProviderException pe) {
                log.warn("Email provider '{}' failed: {}", rp.providerKey(), pe.getMessage());
                last = pe;
            } catch (RuntimeException ex) {
                log.warn("Email provider '{}' threw", rp.providerKey(), ex);
                last = new ProviderException("Provider " + rp.providerKey() + " failed", ex);
            }
        }
        throw last != null
                ? last
                : new ProviderException("All EMAIL providers exhausted");
    }
}