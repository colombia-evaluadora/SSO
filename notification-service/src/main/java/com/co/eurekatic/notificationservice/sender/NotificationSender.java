package com.co.eurekatic.notificationservice.sender;

import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.domain.RenderedNotification;

/**
 * Channel-scoped orchestrator. The consumer dispatches by
 * channel to the matching {@code NotificationSender} bean;
 * the orchestrator is responsible for failover across the
 * registered {@link com.co.eurekatic.notificationservice.provider.ChannelProvider}s,
 * each wrapped in its own circuit breaker.
 *
 * <p>Implemented by {@code SmsSender}, {@code EmailSender},
 * {@code PushSender}. Implementations are looked up by
 * channel at runtime through the
 * {@code NotificationSenderRegistry} — keeping
 * {@link Channel} as the discriminator lets the consumer
 * stay typed without needing an {@code @RabbitListener}
 * per channel.
 */
public interface NotificationSender {

    Channel channel();

    /**
     * Deliver the rendered notification. Must not swallow
     * exceptions: a {@link com.co.eurekatic.notificationservice.provider.ProviderException}
     * signals "recoverable, please retry" and lets the
     * processor pass it to Spring AMQP's retry chain;
     * anything else is treated as a non-recoverable error
     * by the consumer and rejected straight to the DLQ.
     *
     * @return the {@link com.co.eurekatic.notificationservice.provider.ChannelProvider#key()}
     *         of the provider that delivered the message, so
     *         the processor can record it in the
     *         {@code notification_log} row.
     */
    String send(RenderedNotification rendered);
}