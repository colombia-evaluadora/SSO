package com.co.eurekatic.ssoadmin.event;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import org.springframework.amqp.core.TopicExchange;
import org.springframework.amqp.rabbit.connection.ConnectionFactory;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.amqp.support.converter.Jackson2JsonMessageConverter;
import org.springframework.amqp.support.converter.MessageConverter;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.jackson2.autoconfigure.Jackson2ObjectMapperBuilderCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * AMQP wiring for sso-admin's notification-event producer.
 *
 * <p>The producer side only needs the topic exchange — the
 * queue + DLX + bindings live in notification-service. Names
 * are pinned in {@link com.co.eurekatic.notificationservice.config.RabbitProperties}
 * and must match across modules.
 *
 * <p>The publisher confirms + returns (enabled in
 * {@code spring.rabbitmq.*}) surface unroutable messages via
 * the {@link RabbitTemplate} callbacks below — an operator
 * who mistypes a routing key gets a log line instead of a
 * silently dropped message.
 */
@Configuration
public class NotificationsConfig {

    public static final String EXCHANGE = "notifications";

    @Bean
    TopicExchange notificationsExchange() {
        // durable, non-auto-delete — declared identically on
        // the consumer side, both will agree on the topology.
        return new TopicExchange(EXCHANGE, true, false);
    }

    @Bean
    Jackson2ObjectMapperBuilderCustomizer jacksonCustomizer() {
        // Same package move as notification-service: Boot 4
        // relocated the classic Jackson 2.x builder customizer
        // from autoconfigure.jackson to jackson2.autoconfigure.
        return builder -> builder.modules(new JavaTimeModule());
    }

    @Bean
    MessageConverter jacksonMessageConverter(ObjectMapper objectMapper) {
        return new Jackson2JsonMessageConverter(objectMapper);
    }

    @Bean
    RabbitTemplate rabbitTemplate(ConnectionFactory connectionFactory,
                                  MessageConverter converter,
                                  @Value("${spring.application.name:sso-admin}") String source) {
        RabbitTemplate template = new RabbitTemplate(connectionFactory);
        template.setMessageConverter(converter);
        template.setMandatory(true);
        template.setReturnsCallback(returned -> org.slf4j.LoggerFactory.getLogger("amqp.returns")
                .warn("Unroutable AMQP message: exchange={} routingKey={} replyCode={} replyText={}",
                        returned.getExchange(), returned.getRoutingKey(),
                        returned.getReplyCode(), returned.getReplyText()));
        template.setConfirmCallback((correlation, ack, cause) -> {
            if (!ack) {
                org.slf4j.LoggerFactory.getLogger("amqp.confirms")
                        .warn("AMQP publish nack: id={} cause={}", correlation, cause);
            }
        });
        return template;
    }
}