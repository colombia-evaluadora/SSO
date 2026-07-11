package com.co.eurekatic.notificationservice.provider;

import com.co.eurekatic.notificationservice.domain.Channel;
import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.context.event.EventListener;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.ArrayList;
import java.util.EnumMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Single source of truth for the live provider roster.
 *
 * <p>On {@link ApplicationReadyEvent} and every 30 s
 * (driven by {@link Scheduled}), the registry:
 * <ol>
 *   <li>Queries every enabled {@link ProviderConfigRow}
 *       from {@code provider_config}.</li>
 *   <li>Orders the rows via {@link ProviderSelector}
 *       (priority / weighted).</li>
 *   <li>Matches each row to its {@link ChannelProvider} bean
 *       (via {@code providerKey}).</li>
 *   <li>Calls {@link ChannelProvider#isConfigured()} — a
 *       missing env var removes the row from the active
 *       list with a single WARN (never throws, never blocks
 *       startup, unless {@code notif.fail-on-missing-credentials}
 *       is {@code true}).</li>
 *   <li>For live providers, registers / looks up the
 *       per-channel circuit breaker
 *       ({@code "<channel>:<providerKey>"}) and wraps them
 *       in an immutable {@link RegisteredProvider}.</li>
 *   <li>Replaces the per-channel roster atomically via a
 *       {@code volatile} reference, so a refresh in flight
 *       is invisible until it's complete.</li>
 * </ol>
 */
@Component
public class ProviderRegistry {

    private static final Logger log = LoggerFactory.getLogger(ProviderRegistry.class);

    private final ProviderConfigRepository repo;
    private final List<ChannelProvider> providers;
    private final CircuitBreakerRegistry breakers;
    private final ProviderSelector selector;
    private final boolean failOnMissingCredentials;

    private volatile Map<Channel, List<RegisteredProvider>> roster = new EnumMap<>(Channel.class);
    // Settings-by-key is written for a row IMMEDIATELY when it's read from
    // the DB, before isConfigured() is evaluated for that same row — kept
    // separate from `roster` (and mutated in place, not swapped) so a
    // provider's isConfigured() can see its own just-fetched settings via
    // settingsFor(). If it only read from `roster`, a provider would need
    // to already be active to become active — it never would be, on the
    // first refresh or after any prior failed check.
    private final Map<String, Map<String, Object>> settingsByKey = new ConcurrentHashMap<>();
    private volatile Instant lastLoadedAt = Instant.EPOCH;

    public ProviderRegistry(ProviderConfigRepository repo,
                            List<ChannelProvider> providers,
                            CircuitBreakerRegistry breakers,
                            ProviderSelector selector,
                            @Value("${notif.fail-on-missing-credentials:false}") boolean failOnMissingCredentials) {
        this.repo = repo;
        this.providers = providers;
        this.breakers = breakers;
        this.selector = selector;
        this.failOnMissingCredentials = failOnMissingCredentials;
    }

    @EventListener(ApplicationReadyEvent.class)
    public void load() {
        refresh();
    }

    @Scheduled(fixedDelayString = "${notif.provider-config.refresh-interval-ms:30000}",
            initialDelayString = "${notif.provider-config.refresh-interval-ms:30000}")
    @Transactional(readOnly = true)
    public synchronized void refresh() {
        Map<String, ChannelProvider> byKey = new ConcurrentHashMap<>();
        for (ChannelProvider p : providers) {
            byKey.put(p.key(), p);
        }

        StringBuilder summary = new StringBuilder();
        Map<Channel, List<RegisteredProvider>> next = new EnumMap<>(Channel.class);
        for (Channel channel : Channel.values()) {
            List<ProviderConfigRow> rows = repo.findByChannelAndEnabledTrueOrderByPriorityAsc(channel);
            List<ProviderConfigRow> ordered = selector.order(rows);
            List<RegisteredProvider> live = new ArrayList<>();
            for (ProviderConfigRow row : ordered) {
                ChannelProvider bean = byKey.get(row.providerKey());
                if (bean == null) {
                    log.warn("[{}] provider_key '{}' (impl={}) has no bean — skipping",
                            channel, row.providerKey(), row.impl());
                    continue;
                }
                // Written before isConfigured() runs so the check can see
                // this row's own settings via settingsFor() — see the field
                // comment on settingsByKey.
                settingsByKey.put(row.providerKey(), row.settings());
                boolean configured;
                try {
                    configured = bean.isConfigured();
                } catch (RuntimeException ex) {
                    log.warn("[{}] provider '{}' isConfigured() threw: {}",
                            channel, row.providerKey(), ex.toString());
                    configured = false;
                }
                if (!configured) {
                    if (failOnMissingCredentials) {
                        throw new IllegalStateException(
                                "Provider " + row.providerKey() + " not configured and fail-on-missing-credentials=true");
                    }
                    log.warn("[{}] provider '{}' disabled — credentials missing",
                            channel, row.providerKey());
                    continue;
                }
                CircuitBreaker breaker = breakers.circuitBreaker(
                        channel.name().toLowerCase() + ":" + row.providerKey());
                live.add(new RegisteredProvider(row, bean, breaker));
            }
            next.put(channel, List.copyOf(live));
            if (summary.length() > 0) summary.append(",");
            summary.append(channel.name()).append("=").append(live.size());
        }
        this.roster = next;
        this.lastLoadedAt = Instant.now();
        log.info("ProviderRegistry refreshed: {}", summary.toString());
    }

    public List<RegisteredProvider> providersFor(Channel channel) {
        return roster.getOrDefault(channel, List.of());
    }

    public Instant lastLoadedAt() {
        return lastLoadedAt;
    }

    /**
     * Convenience for individual {@link ChannelProvider}
     * implementations that don't want to be wired through
     * the orchestrator (e.g. {@code SmtpEmailProvider} reads
     * its host/port/credentials on every call).
     *
     * @return the latest settings JSON for {@code providerKey} as of the
     *         last refresh, or empty if its {@code provider_config} row is
     *         disabled (or doesn't exist). Available even when the provider
     *         isn't currently in the active roster — {@code isConfigured()}
     *         implementations call this to decide whether they belong there.
     */
    public Optional<Map<String, Object>> settingsFor(String providerKey) {
        return Optional.ofNullable(settingsByKey.get(providerKey));
    }

    /**
     * Channel a given provider_key serves, or empty if the
     * key isn't in the live roster.
     */
    public Optional<Channel> channelFor(String providerKey) {
        for (Map.Entry<Channel, List<RegisteredProvider>> e : roster.entrySet()) {
            for (RegisteredProvider rp : e.getValue()) {
                if (rp.providerKey().equals(providerKey)) {
                    return Optional.of(e.getKey());
                }
            }
        }
        return Optional.empty();
    }

    /** (provider-config-row, channel-provider-bean, circuit-breaker). */
    public record RegisteredProvider(
            ProviderConfigRow row,
            ChannelProvider provider,
            CircuitBreaker circuitBreaker
    ) {
        public String providerKey() { return row.providerKey(); }
    }
}