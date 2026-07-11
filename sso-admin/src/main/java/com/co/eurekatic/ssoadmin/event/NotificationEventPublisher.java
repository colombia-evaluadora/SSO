package com.co.eurekatic.ssoadmin.event;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.stereotype.Component;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

/**
 * Publishes a {@code NotificationMessage}-shaped envelope to
 * the {@link NotificationsConfig#EXCHANGE} topic exchange.
 * Routing key is the channel name in lower case
 * ({@code sms}, {@code email}, {@code push}) — the consumer's
 * per-channel queues are bound to those keys.
 *
 * <p>The schema mirrors the consumer's
 * {@code com.co.eurekatic.notificationservice.domain.NotificationMessage}
 * record 1-1, including the {@code JsonProperty} mappings
 * for the snake-case keys. We don't share the record class
 * across modules (avoids a circular dep) — the contract is
 * the JSON shape on the wire.
 *
 * <p>Publishes are fire-and-forget; failures log at WARN
 * (the user creation flow shouldn't 500 because the broker
 * is down). Once notification-service is healthy, an
 * operator can replay queued events from the operator's
 * audit table.
 */
@Component
public class NotificationEventPublisher {

    private static final Logger log = LoggerFactory.getLogger(NotificationEventPublisher.class);

    private final RabbitTemplate rabbit;

    public NotificationEventPublisher(RabbitTemplate rabbit) {
        this.rabbit = rabbit;
    }

    /**
     * Publish a notification event.
     *
     * @param channel     {@code "sms"} / {@code "email"} / {@code "push"}
     *                    — also the routing key.
     * @param userId      recipient user id (may be {@code null} for
     *                    admin broadcasts).
     * @param address     recipient address (E.164 phone / email /
     *                    device token). Required.
     * @param templateId  template file name (without extension) under
     *                    {@code templates/<channel>/}.
     * @param payload     variables merged into the template.
     * @param correlationId caller's trace id (may be {@code null}).
     */
    public void publish(String channel,
                        String userId,
                        String address,
                        String templateId,
                        Map<String, Object> payload,
                        String correlationId) {
        UUID notificationId = UUID.randomUUID();
        Map<String, Object> metadata = new LinkedHashMap<>();
        metadata.put("source", "sso-admin");
        metadata.put("correlationId", correlationId);
        metadata.put("timestamp", Instant.now().toString());

        Map<String, Object> envelope = new LinkedHashMap<>();
        envelope.put("notificationId", notificationId.toString());
        envelope.put("channel", channel.toUpperCase());
        envelope.put("recipient", Map.of(
                "userId", userId == null ? "" : userId,
                "address", address));
        envelope.put("templateId", templateId);
        envelope.put("payload", payload);
        envelope.put("metadata", metadata);

        try {
            rabbit.convertAndSend(NotificationsConfig.EXCHANGE, channel.toLowerCase(), envelope);
            log.info("Published notification {} channel={} template={} to={}",
                    notificationId, channel, templateId, address);
        } catch (RuntimeException ex) {
            log.warn("Failed to publish notification {} (channel={}, template={}): {}",
                    notificationId, channel, templateId, ex.toString());
        }
    }
}