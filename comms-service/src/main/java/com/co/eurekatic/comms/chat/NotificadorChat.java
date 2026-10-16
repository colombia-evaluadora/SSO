package com.co.eurekatic.comms.chat;

import com.co.eurekatic.comms.config.CommsProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.AmqpException;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.stereotype.Component;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Eventos de notificacion hacia notification-service: exchange
 * {@code notifications}, routing key {@code evento} (cola {@code notif.eventos}).
 * Forma: {@code EventoNotificacion} de notification-service. Se llama tras el
 * commit; si RabbitMQ falla se registra y el mensaje del chat sigue valido.
 */
@Component
public class NotificadorChat {

    private static final Logger log = LoggerFactory.getLogger(NotificadorChat.class);

    private final RabbitTemplate rabbit;
    private final CommsProperties props;

    public NotificadorChat(RabbitTemplate rabbit, CommsProperties props) {
        this.rabbit = rabbit;
        this.props = props;
    }

    public void enviar(String tipo, List<String> destinatarios, String titulo, String cuerpo, String deepLink,
                       Map<String, Object> datos, String dedupeKey, String agrupacionKey, String actor) {
        if (destinatarios.isEmpty()) return;
        Map<String, Object> ev = new LinkedHashMap<>();
        ev.put("tipo", tipo);
        ev.put("destinatarios", destinatarios);
        ev.put("app", props.app());
        ev.put("titulo", titulo);
        ev.put("cuerpo", cuerpo);
        ev.put("deepLink", deepLink);
        ev.put("datos", datos);
        ev.put("dedupeKey", dedupeKey);
        ev.put("agrupacionKey", agrupacionKey);
        ev.put("actor", actor);
        try {
            rabbit.convertAndSend(props.exchangeNotificaciones(), "evento", ev);
        } catch (AmqpException e) {
            log.warn("No se pudo emitir la notificacion {}: {}", tipo, e.getMessage());
        }
    }
}
