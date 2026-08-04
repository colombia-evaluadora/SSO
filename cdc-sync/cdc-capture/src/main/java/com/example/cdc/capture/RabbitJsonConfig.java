package com.example.cdc.capture;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.support.converter.Jackson2JsonMessageConverter;
import org.springframework.amqp.support.converter.MessageConverter;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Defines Jackson2JsonMessageConverter so Spring Boot's RabbitAutoConfiguration
 * picks it up via {@code RabbitTemplateConfigurer.setMessageConverter(messageConverter.getIfUnique())}
 * and applies it to the autoconfigured RabbitTemplate.
 *
 * <p>Without this bean the capture uses the default {@code SimpleMessageConverter},
 * which serializes the envelope Map via {@code java.io.ObjectOutputStream}.
 * The downstream worker then sees {@code content_type=application/x-java-serialized-object}
 * and chokes on the binary payload
 * ({@code Unexpected character ('¬' (code 172))} when the bytes are forced through
 * the UTF-8 decoder).
 *
 * <p>Defining only the MessageConverter bean (not a full RabbitTemplate) lets
 * Spring Boot keep its autoconfigured RabbitTemplate — which already picks up
 * retry settings, mandatory publishing, etc. — while just swapping in the JSON
 * converter.
 */
@Configuration
public class RabbitJsonConfig {

    private static final Logger log = LoggerFactory.getLogger(RabbitJsonConfig.class);

    @Bean
    public MessageConverter jacksonMessageConverter() {
        Jackson2JsonMessageConverter c = new Jackson2JsonMessageConverter();
        log.info("Jackson2JsonMessageConverter bean created (class={})", c.getClass().getName());
        return c;
    }
}