package com.co.eurekatic.notificationservice.provider;

import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.domain.RenderedNotification;

/**
 * A concrete delivery mechanism for one channel (e.g.
 * Twilio for SMS, Brevo SMTP for email, FCM for push).
 *
 * <p>Implementations are picked up by the orchestrators
 * (e.g. {@code SmsSender}) via constructor injection of a
 * {@code List<ChannelProvider>} and filtered by
 * {@link #channel()}. Per-provider ordering, weighting,
 * and circuit-breaker wiring happen one layer up in the
 * orchestrator — implementations just have to deliver the
 * message or throw a {@link ProviderException}.
 *
 * <p>The {@link #isConfigured()} hook lets the registry
 * auto-disable a provider whose required credentials are
 * absent at runtime, without crashing startup.
 */
public interface ChannelProvider {

    /** Stable identifier, e.g. {@code "twilio"}, {@code "fcm"}. */
    String key();

    /** Channel this provider serves. */
    Channel channel();

    /**
     * Actually deliver the message. On a recoverable failure
     * (timeout, 5xx, rate limit) wrap the cause in
     * {@link ProviderException}; on a permanent failure let a
     * different exception (typically
     * {@link com.co.eurekatic.notificationservice.template.TemplateNotFoundException}
     * or an {@link IllegalArgumentException}) bubble up so
     * the processor routes it straight to the DLQ without
     * retry.
     */
    void deliver(RenderedNotification rendered);

    /**
     * Cheap credential check used at startup and on every
     * {@code /actuator/providers/refresh}. Implementations
     * inspect the {@code provider_config.settings} JSON for
     * the env-var names and resolve them via
     * {@link System#getenv(String)}. Returning {@code false}
     * logs a single WARN at first detection and removes the
     * provider from the active roster — no exception, no
     * crash.
     */
    boolean isConfigured();
}