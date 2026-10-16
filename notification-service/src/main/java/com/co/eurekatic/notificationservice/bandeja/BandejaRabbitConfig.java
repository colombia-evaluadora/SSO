package com.co.eurekatic.notificationservice.bandeja;

import com.co.eurekatic.notificationservice.config.RabbitProperties;
import org.springframework.amqp.core.Binding;
import org.springframework.amqp.core.BindingBuilder;
import org.springframework.amqp.core.DirectExchange;
import org.springframework.amqp.core.Queue;
import org.springframework.amqp.core.QueueBuilder;
import org.springframework.amqp.core.TopicExchange;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Topologia de la bandeja, junto a la de canales ({@code RabbitTopologyConfig}):
 * <ul>
 *   <li>{@code notif.eventos} en el exchange {@code notifications} con routing
 *       key {@code evento}; sus rechazos van a {@code notif.eventos.dlq};</li>
 *   <li>el exchange {@code comms.realtime} (topic) donde se publican los eventos
 *       de tiempo real. Lo declara tambien comms-service: quien arranque primero
 *       lo crea y el otro lo encuentra.</li>
 * </ul>
 */
@Configuration
public class BandejaRabbitConfig {

    static final String ROUTING_EVENTO = "evento";

    @Bean
    Queue eventosQueue(RabbitProperties props, @Value("${notif.bandeja.cola-eventos:notif.eventos}") String cola) {
        return QueueBuilder.durable(cola)
                .withArgument("x-dead-letter-exchange", props.dlx())
                .withArgument("x-dead-letter-routing-key", ROUTING_EVENTO + "." + props.dlqSuffix())
                .build();
    }

    @Bean
    Queue eventosDlq(RabbitProperties props, @Value("${notif.bandeja.cola-eventos:notif.eventos}") String cola) {
        return QueueBuilder.durable(cola + "." + props.dlqSuffix()).build();
    }

    @Bean
    Binding eventosBinding(Queue eventosQueue, TopicExchange notificationsExchange) {
        return BindingBuilder.bind(eventosQueue).to(notificationsExchange).with(ROUTING_EVENTO);
    }

    @Bean
    Binding eventosDlqBinding(Queue eventosDlq, DirectExchange notificationsDlx, RabbitProperties props) {
        return BindingBuilder.bind(eventosDlq).to(notificationsDlx).with(ROUTING_EVENTO + "." + props.dlqSuffix());
    }

    @Bean
    TopicExchange tiempoRealExchange(@Value("${notif.realtime.exchange:comms.realtime}") String nombre) {
        return new TopicExchange(nombre, true, false);
    }
}
