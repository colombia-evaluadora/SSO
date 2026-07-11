package com.co.eurekatic.notificationservice.consumer;

import com.co.eurekatic.notificationservice.config.RabbitProperties;
import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.domain.NotificationMessage;
import com.co.eurekatic.notificationservice.service.NotificationProcessor;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.stereotype.Component;

/**
 * One {@link RabbitListener} per channel. The concurrency
 * values match the spec — SMS is low-volume and cheapest,
 * PUSH is highest volume so it gets the most consumers.
 * Queues + bindings are declared by
 * {@link com.co.eurekatic.notificationservice.config.RabbitTopologyConfig}.
 *
 * <p>The listener container applies the channel-level
 * retry (see {@code spring.rabbitmq.listener.simple.retry}
 * in {@code application.yml}) automatically: a
 * {@link org.springframework.amqp.AmqpRejectAndDontRequeueException}
 * short-circuits the retry and goes to the DLQ; a plain
 * {@link RuntimeException} (e.g. a {@code ProviderException})
 * counts toward the retry budget; once exhausted the
 * message is rejected with {@code requeue=false} and lands
 * in the channel's DLQ.
 */
@Component
public class NotificationConsumers {

    private static final Logger log = LoggerFactory.getLogger(NotificationConsumers.class);

    private final NotificationProcessor processor;

    public NotificationConsumers(NotificationProcessor processor) {
        this.processor = processor;
    }

    @RabbitListener(queues = "#{@rabbitProperties.queueName(T(com.co.eurekatic.notificationservice.domain.Channel).SMS)}",
            concurrency = "2-5")
    public void onSms(NotificationMessage message) {
        log.debug("Received SMS {}", message.notificationId());
        processor.process(message, Channel.SMS);
    }

    @RabbitListener(queues = "#{@rabbitProperties.queueName(T(com.co.eurekatic.notificationservice.domain.Channel).EMAIL)}",
            concurrency = "3-10")
    public void onEmail(NotificationMessage message) {
        log.debug("Received EMAIL {}", message.notificationId());
        processor.process(message, Channel.EMAIL);
    }

    @RabbitListener(queues = "#{@rabbitProperties.queueName(T(com.co.eurekatic.notificationservice.domain.Channel).PUSH)}",
            concurrency = "5-20")
    public void onPush(NotificationMessage message) {
        log.debug("Received PUSH {}", message.notificationId());
        processor.process(message, Channel.PUSH);
    }
}