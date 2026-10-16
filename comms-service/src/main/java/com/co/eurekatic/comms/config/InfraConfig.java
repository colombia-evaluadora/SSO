package com.co.eurekatic.comms.config;

import com.co.eurekatic.comms.realtime.RealtimeBus;
import com.co.eurekatic.comms.realtime.RealtimeHandler;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.amqp.core.Binding;
import org.springframework.amqp.core.BindingBuilder;
import org.springframework.amqp.core.Queue;
import org.springframework.amqp.core.QueueBuilder;
import org.springframework.amqp.core.TopicExchange;
import org.springframework.amqp.rabbit.connection.ConnectionFactory;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.amqp.support.converter.Jackson2JsonMessageConverter;
import org.springframework.amqp.support.converter.MessageConverter;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.listener.ChannelTopic;
import org.springframework.data.redis.listener.RedisMessageListenerContainer;
import org.springframework.web.socket.config.annotation.EnableWebSocket;
import org.springframework.web.socket.config.annotation.WebSocketConfigurer;
import org.springframework.web.socket.config.annotation.WebSocketHandlerRegistry;

/**
 * Infraestructura: WebSocket en {@code /comms/ws}, suscripcion Redis del bus y
 * topologia RabbitMQ (exchange {@code comms.realtime} de entrada; los eventos
 * de notificacion salen por el exchange {@code notifications} con routing key
 * {@code evento}, que declara y consume notification-service).
 */
@Configuration
@EnableWebSocket
public class InfraConfig implements WebSocketConfigurer {

    private final RealtimeHandler handler;
    private final String origenes;

    public InfraConfig(RealtimeHandler handler, @Value("${comms.ws.allowed-origins:*}") String origenes) {
        this.handler = handler;
        this.origenes = origenes;
    }

    @Override
    public void registerWebSocketHandlers(WebSocketHandlerRegistry registry) {
        registry.addHandler(handler, "/comms/ws").setAllowedOriginPatterns(origenes.split(","));
    }

    @Bean
    RedisMessageListenerContainer redisRt(RedisConnectionFactory cf, RealtimeBus bus) {
        RedisMessageListenerContainer c = new RedisMessageListenerContainer();
        c.setConnectionFactory(cf);
        c.addMessageListener(bus, new ChannelTopic(RealtimeBus.CANAL_REDIS));
        return c;
    }

    @Bean
    TopicExchange tiempoRealExchange(CommsProperties p) {
        return new TopicExchange(p.exchangeTiempoReal(), true, false);
    }

    @Bean
    Queue tiempoRealEntrada(@Value("${comms.cola-tiempo-real:comms.realtime.entrada}") String nombre) {
        return QueueBuilder.durable(nombre).build();
    }

    @Bean
    Binding tiempoRealBinding(Queue tiempoRealEntrada, TopicExchange tiempoRealExchange) {
        return BindingBuilder.bind(tiempoRealEntrada).to(tiempoRealExchange).with("#");
    }

    @Bean
    MessageConverter jacksonMessageConverter(ObjectMapper commsObjectMapper) {
        return new Jackson2JsonMessageConverter(commsObjectMapper);
    }

    @Bean
    RabbitTemplate rabbitTemplate(ConnectionFactory cf, MessageConverter jacksonMessageConverter) {
        RabbitTemplate t = new RabbitTemplate(cf);
        t.setMessageConverter(jacksonMessageConverter);
        return t;
    }
}
