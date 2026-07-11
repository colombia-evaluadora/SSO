package com.co.eurekatic.notificationservice.config;

import com.co.eurekatic.notificationservice.domain.Channel;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.amqp.core.Binding;
import org.springframework.amqp.core.BindingBuilder;
import org.springframework.amqp.core.DirectExchange;
import org.springframework.amqp.core.Queue;
import org.springframework.amqp.core.QueueBuilder;
import org.springframework.amqp.core.TopicExchange;
import org.springframework.amqp.rabbit.connection.ConnectionFactory;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.amqp.support.converter.Jackson2JsonMessageConverter;
import org.springframework.amqp.support.converter.MessageConverter;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Declares the RabbitMQ topology per the spec:
 *
 * <pre>
 *   notifications (topic)        notifications.dlx (direct)
 *       │ sms  ──▶ notif.sms   ──DLX─▶ notif.sms.dlq
 *       │ email ──▶ notif.email ──DLX─▶ notif.email.dlq
 *       │ push  ──▶ notif.push  ──DLX─▶ notif.push.dlq  (TTL 300_000)
 * </pre>
 *
 * <p>All queues and exchanges are declared as beans so Spring
 * AMQP creates them on startup with the right arguments
 * (durability, DLX, TTL). Producer code (e.g. the
 * integration tests) uses the {@link RabbitTemplate}
 * configured with the {@link Jackson2JsonMessageConverter}
 * — the converter is the global default for every
 * {@code @RabbitListener} too, so the typed
 * {@code NotificationMessage} record is deserialised
 * without an explicit {@code @RabbitHandler} method.
 */
@Configuration
public class RabbitTopologyConfig {

    /**
     * Registers {@link RabbitProperties} as a bean named
     * {@code rabbitProperties} (method name = bean id). This
     * preserves {@code @ConfigurationProperties} binding —
     * Spring Boot scans the {@code notif.rabbit.*} keys and
     * binds them via the record's canonical ctor — while also
     * exposing the bean under a name that {@code @RabbitListener}'s
     * SpEL expression {@code #{@rabbitProperties.queueName(...)}}
     * can resolve.
     */
    @Bean
    public RabbitProperties rabbitProperties() {
        return new RabbitProperties(null, null, null, null, 0);
    }

    @Bean
    TopicExchange notificationsExchange(RabbitProperties props) {
        return new TopicExchange(props.exchange(), true, false);
    }

    @Bean
    DirectExchange notificationsDlx(RabbitProperties props) {
        return new DirectExchange(props.dlx(), true, false);
    }

    @Bean
    Queue smsQueue(RabbitProperties props) {
        return channelQueue(props, Channel.SMS);
    }

    @Bean
    Queue emailQueue(RabbitProperties props) {
        return channelQueue(props, Channel.EMAIL);
    }

    @Bean
    Queue pushQueue(RabbitProperties props) {
        // Spec: only the push queue carries x-message-ttl.
        return QueueBuilder.durable(props.queueName(Channel.PUSH))
                .withArgument("x-dead-letter-exchange", props.dlx())
                .withArgument("x-dead-letter-routing-key", props.dlxRoutingKey(Channel.PUSH))
                .withArgument("x-message-ttl", props.pushTtlMs())
                .build();
    }

    @Bean
    Queue smsDlq(RabbitProperties props) {
        return QueueBuilder.durable(props.dlqName(Channel.SMS)).build();
    }

    @Bean
    Queue emailDlq(RabbitProperties props) {
        return QueueBuilder.durable(props.dlqName(Channel.EMAIL)).build();
    }

    @Bean
    Queue pushDlq(RabbitProperties props) {
        return QueueBuilder.durable(props.dlqName(Channel.PUSH)).build();
    }

    @Bean
    Binding smsBinding(Queue smsQueue, TopicExchange notificationsExchange) {
        return BindingBuilder.bind(smsQueue).to(notificationsExchange).with(Channel.SMS.name().toLowerCase());
    }

    @Bean
    Binding emailBinding(Queue emailQueue, TopicExchange notificationsExchange) {
        return BindingBuilder.bind(emailQueue).to(notificationsExchange).with(Channel.EMAIL.name().toLowerCase());
    }

    @Bean
    Binding pushBinding(Queue pushQueue, TopicExchange notificationsExchange) {
        return BindingBuilder.bind(pushQueue).to(notificationsExchange).with(Channel.PUSH.name().toLowerCase());
    }

    @Bean
    Binding smsDlqBinding(Queue smsDlq, DirectExchange notificationsDlx, RabbitProperties props) {
        return BindingBuilder.bind(smsDlq).to(notificationsDlx).with(props.dlxRoutingKey(Channel.SMS));
    }

    @Bean
    Binding emailDlqBinding(Queue emailDlq, DirectExchange notificationsDlx, RabbitProperties props) {
        return BindingBuilder.bind(emailDlq).to(notificationsDlx).with(props.dlxRoutingKey(Channel.EMAIL));
    }

    @Bean
    Binding pushDlqBinding(Queue pushDlq, DirectExchange notificationsDlx, RabbitProperties props) {
        return BindingBuilder.bind(pushDlq).to(notificationsDlx).with(props.dlxRoutingKey(Channel.PUSH));
    }

    @Bean
    MessageConverter jacksonMessageConverter(ObjectMapper objectMapper) {
        return new Jackson2JsonMessageConverter(objectMapper);
    }

    @Bean
    RabbitTemplate rabbitTemplate(ConnectionFactory connectionFactory,
                                 MessageConverter jacksonMessageConverter) {
        RabbitTemplate template = new RabbitTemplate(connectionFactory);
        template.setMessageConverter(jacksonMessageConverter);
        return template;
    }

    private static Queue channelQueue(RabbitProperties props, Channel channel) {
        return QueueBuilder.durable(props.queueName(channel))
                .withArgument("x-dead-letter-exchange", props.dlx())
                .withArgument("x-dead-letter-routing-key", props.dlxRoutingKey(channel))
                .build();
    }
}
