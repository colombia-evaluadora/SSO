package com.co.eurekatic.comms.realtime;

import com.co.eurekatic.comms.security.Usuario;
import com.fasterxml.jackson.databind.JsonNode;
import jakarta.servlet.http.HttpServletRequest;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * {@code POST /comms/ws-ticket} (Bearer) → {@code {ticket, expiresIn}}; y la
 * entrada de eventos de otros servicios (notification-service publica
 * {@code {topic, event, data}} en el exchange {@code comms.realtime}).
 */
@RestController
public class RealtimeController {

    private static final Logger log = LoggerFactory.getLogger(RealtimeController.class);

    private final TicketService tickets;
    private final RealtimeBus bus;

    public RealtimeController(TicketService tickets, RealtimeBus bus) {
        this.tickets = tickets;
        this.bus = bus;
    }

    @PostMapping("/comms/ws-ticket")
    public TicketService.Ticket ticket(HttpServletRequest req) {
        return tickets.emitir(Usuario.de(req));
    }

    @RabbitListener(queues = "${comms.cola-tiempo-real:comms.realtime.entrada}", concurrency = "1-4")
    public void entrada(JsonNode msg) {
        String topic = msg.path("topic").asText("");
        String event = msg.path("event").asText("");
        // Solo topicos de usuario: un servicio externo no inyecta eventos en canales.
        if (!topic.startsWith("user:") || event.isBlank()) {
            log.warn("Evento de tiempo real descartado: topico {} evento {}", topic, event);
            return;
        }
        bus.publicar(topic, event, msg.path("data"));
    }
}
