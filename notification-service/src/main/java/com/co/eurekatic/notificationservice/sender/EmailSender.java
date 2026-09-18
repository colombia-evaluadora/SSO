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

import java.util.List;

/**
 * EMAIL orchestrator — same shape as {@link SmsSender}, plus
 * app-scoped provider filtering (SMS/PUSH don't need this yet:
 * only EMAIL has two accounts tied to two different apps' verified
 * domains).
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
        var providers = providersFor(rendered.appName());
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

    /**
     * The full EMAIL roster, filtered to rows scoped to {@code appName}
     * plus the app-agnostic ones ({@code ProviderConfigRow.appName() ==
     * null}, e.g. a generic Gmail fallback) — never a DIFFERENT app's row,
     * so a PIGSE password-reset can't silently go out under Colombia
     * Evaluadora's verified domain (or vice versa) just because that
     * account happened to be healthy.
     *
     * <p>{@code appName == null} (most producers don't set one) skips the
     * filter entirely — same roster as before this feature existed.
     *
     * <p>Falls back to the unfiltered roster if the filter would leave
     * NOTHING (e.g. no row is scoped for this app yet and every row
     * happens to be app-scoped for some other app) — the old
     * priority/failover behavior is a safer default than refusing to send
     * a notification outright over a routing rule that isn't complete
     * yet.
     */
    private List<ProviderRegistry.RegisteredProvider> providersFor(String appName) {
        var all = registry.providersFor(Channel.EMAIL);
        if (appName == null) return all;
        var scoped = all.stream()
                .filter(rp -> rp.row().appName() == null || appName.equalsIgnoreCase(rp.row().appName()))
                .toList();
        return scoped.isEmpty() ? all : scoped;
    }
}