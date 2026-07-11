package com.co.eurekatic.notificationservice.config;

import com.co.eurekatic.notificationservice.domain.Channel;
import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Typed binding for the Rabbit topology block. Bound under
 * {@code notif.rabbit.*}. The defaults match the spec
 * exactly; production deployments should NOT override
 * these names (the contract with sso-admin pins them).
 *
 * <p>This record is registered as a bean named
 * {@code rabbitProperties} via the {@code @Bean} factory in
 * {@link RabbitTopologyConfig}, which keeps both the
 * {@code @ConfigurationProperties} binding intact AND gives
 * the bean the name expected by the {@code @RabbitListener}
 * SpEL in
 * {@link com.co.eurekatic.notificationservice.consumer.NotificationConsumers}.
 * {@code @EnableConfigurationProperties(RabbitProperties.class)}
 * alone registers it under the prefixed-class-name
 * ({@code notif.rabbit-com.co.eurekatic.notificationservice.config.RabbitProperties}),
 * which that SpEL can't find, and {@code @Component} on the
 * record breaks binding because Spring tries constructor
 * injection on the record's canonical ctor instead.
 */
@ConfigurationProperties(prefix = "notif.rabbit")
public record RabbitProperties(
        String exchange,
        String dlx,
        String queuePrefix,
        String dlqSuffix,
        int pushTtlMs
) {

    public RabbitProperties {
        if (exchange == null) exchange = "notifications";
        if (dlx == null) dlx = "notifications.dlx";
        if (queuePrefix == null) queuePrefix = "notif";
        if (dlqSuffix == null) dlqSuffix = "dlq";
        if (pushTtlMs == 0) pushTtlMs = 300_000;
    }

    /** Queue name for a given channel, e.g. {@code notif.email}. */
    public String queueName(Channel channel) {
        return queuePrefix + "." + channel.name().toLowerCase();
    }

    /** DLQ name for a given channel, e.g. {@code notif.email.dlq}. */
    public String dlqName(Channel channel) {
        return queueName(channel) + "." + dlqSuffix;
    }

    /** DLX routing key for a given channel, e.g. {@code email.dlq}. */
    public String dlxRoutingKey(Channel channel) {
        return channel.name().toLowerCase() + "." + dlqSuffix;
    }
}
