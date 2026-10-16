package com.co.eurekatic.notificationservice.bandeja;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.AmqpException;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Publica eventos de la bandeja hacia el gateway de tiempo real (comms-service)
 * por el exchange {@code comms.realtime}: {@code {topic, event, data}}.
 * comms-service les asigna el {@code seq} del topico y los difunde por
 * WebSocket (OpenSpec add-tiempo-real-gateway D-1.3).
 *
 * <p>Eventos (D-2.5), siempre en el topico {@code user:<sub>}:
 * {@code notification.created}, {@code notification.read},
 * {@code notification.read_all}, {@code notification.archived}.
 *
 * <p>Best-effort: el WS no es fuente de verdad (D-1.6). Si RabbitMQ falla se
 * registra y la escritura REST sigue valida; el cliente se pone al dia por REST.
 */
@Component
public class TiempoRealPublisher {

    private static final Logger log = LoggerFactory.getLogger(TiempoRealPublisher.class);

    private final RabbitTemplate rabbit;
    private final String exchange;

    public TiempoRealPublisher(RabbitTemplate rabbit,
                               @Value("${notif.realtime.exchange:comms.realtime}") String exchange) {
        this.rabbit = rabbit;
        this.exchange = exchange;
    }

    public void alUsuario(String sub, String evento, Object data) {
        Map<String, Object> msg = new LinkedHashMap<>();
        msg.put("topic", "user:" + sub);
        msg.put("event", evento);
        msg.put("data", data);
        try {
            rabbit.convertAndSend(exchange, "user", msg);
        } catch (AmqpException e) {
            log.warn("No se pudo publicar {} en tiempo real: {}", evento, e.getMessage());
        }
    }
}
