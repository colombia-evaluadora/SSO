package com.example.cdc.worker;

import org.springframework.amqp.rabbit.config.SimpleRabbitListenerContainerFactory;
import org.springframework.amqp.rabbit.connection.ConnectionFactory;
import org.springframework.amqp.support.converter.Jackson2JsonMessageConverter;
import org.springframework.amqp.support.converter.MessageConverter;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.amqp.autoconfigure.SimpleRabbitListenerContainerFactoryConfigurer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Wires Jackson2JsonMessageConverter into the listener container factory.
 *
 * <p>Spring Boot autoconfigures Jackson2JsonMessageConverter on RabbitTemplate (the producer
 * side) but NOT on the listener container factory. Without this bean the consumer falls back
 * to SimpleMessageConverter, which tries Java serialization on the raw JSON bytes coming
 * from cdc-capture and throws
 * {@code SecurityException: Attempt to deserialize unauthorized class java.util.LinkedHashMap}.
 *
 * <p>We set the converter on the factory via {@link SimpleRabbitListenerContainerFactoryConfigurer}
 * so all properties from {@code spring.rabbitmq.listener.simple.*} (prefetch, ack-mode, retry)
 * remain respected.
 */
@Configuration
public class RabbitJsonConfig {

    @Bean
    public MessageConverter jackson2JsonMessageConverter() {
        return new Jackson2JsonMessageConverter();
    }

    /**
     * Consumo por lotes: el contenedor entrega hasta {@code batchSize}
     * mensajes, o los que hayan llegado en {@code batchWaitMs}, en una sola
     * llamada a AmqpConsumer#onMessages. batchWaitMs es lo maximo que se
     * suma a la latencia del CDC cuando el trafico es bajo (el valor por
     * defecto de Spring AMQP es 1 s).
     */
    @Bean
    public SimpleRabbitListenerContainerFactory rabbitListenerContainerFactory(
            ConnectionFactory connectionFactory,
            SimpleRabbitListenerContainerFactoryConfigurer configurer,
            MessageConverter jackson2JsonMessageConverter,
            @Value("${cdc.worker.batch-size:100}") int batchSize,
            @Value("${cdc.worker.batch-wait-ms:200}") long batchWaitMs) {
        SimpleRabbitListenerContainerFactory factory = new SimpleRabbitListenerContainerFactory();
        configurer.configure(factory, connectionFactory);
        factory.setMessageConverter(jackson2JsonMessageConverter);
        factory.setBatchListener(true);
        factory.setConsumerBatchEnabled(true);
        factory.setBatchSize(batchSize);
        factory.setReceiveTimeout(batchWaitMs);
        return factory;
    }
}