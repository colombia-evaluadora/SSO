package com.co.eurekatic.comms.realtime;

import com.co.eurekatic.comms.chat.ChatRepository;
import com.co.eurekatic.comms.realtime.SesionesLocales.Conexion;
import com.co.eurekatic.comms.security.Usuario;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.TextWebSocketHandler;

import java.io.IOException;
import java.net.URI;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Map;

/**
 * Protocolo del socket (front: {@code src/lib/realtime/protocol.ts}).
 *
 * <p>Cliente: {@code subscribe | resume{afterSeq} | unsubscribe | ephemeral | ping}.
 * Servidor: {@code event | subscribed{seq} | resync{seq} | error{forbidden|bad-request} | pong}.
 * Cierres: 4001 ticket invalido o token vencido (el cliente refresca y pide otro
 * ticket), 4003 acceso revocado (no reintenta).
 *
 * <p>Topicos: {@code user:<sub>} solo el propio; {@code canal:<id>} solo
 * miembros activos no bloqueados; {@code presencia} cualquiera.
 */
@Component
public class RealtimeHandler extends TextWebSocketHandler {

    public static final int CLOSE_TOKEN_EXPIRED = 4001;
    public static final int CLOSE_FORBIDDEN = 4003;
    private static final Duration ESCRIBIENDO_MIN = Duration.ofSeconds(2);

    private final TicketService tickets;
    private final SesionesLocales sesiones;
    private final RealtimeBus bus;
    private final PresenciaService presencia;
    private final ChatRepository chat;
    private final StringRedisTemplate redis;
    private final ObjectMapper json;

    public RealtimeHandler(TicketService tickets, SesionesLocales sesiones, RealtimeBus bus,
                           PresenciaService presencia, ChatRepository chat, StringRedisTemplate redis,
                           ObjectMapper json) {
        this.tickets = tickets;
        this.sesiones = sesiones;
        this.bus = bus;
        this.presencia = presencia;
        this.chat = chat;
        this.redis = redis;
        this.json = json;
    }

    @Override
    public void afterConnectionEstablished(WebSocketSession s) throws IOException {
        Usuario u = tickets.consumir(ticketDe(s.getUri()));
        if (u == null || (u.expira() != null && u.expira().isBefore(Instant.now()))) {
            s.close(new CloseStatus(CLOSE_TOKEN_EXPIRED, "ticket"));
            return;
        }
        sesiones.registrar(s, u);
        if (presencia.latido(u.id(), s.getId())) {
            bus.efimero("presencia", "presencia.actualizada", PresenciaService.evento(u.id(), u.nombre(), true), null);
        }
    }

    @Override
    protected void handleTextMessage(WebSocketSession s, TextMessage message) {
        Conexion c = sesiones.get(s.getId());
        if (c == null) return;
        JsonNode m;
        try {
            m = json.readTree(message.getPayload());
        } catch (IOException e) {
            error(c, null, "bad-request");
            return;
        }
        String tipo = m.path("type").asText();
        String topic = m.path("topic").asText(null);
        switch (tipo) {
            case "ping" -> {
                presencia.latido(c.usuario().id(), s.getId());
                sesiones.enviar(c, "{\"type\":\"pong\"}");
            }
            case "subscribe", "resume" -> suscribir(c, topic, "resume".equals(tipo) ? m.path("afterSeq").asLong(-1) : -1);
            case "unsubscribe" -> {
                if (topic != null) c.topicos().remove(topic);
            }
            case "ephemeral" -> efimero(c, topic, m.path("event").asText(""));
            default -> error(c, topic, "bad-request");
        }
    }

    @Override
    public void afterConnectionClosed(WebSocketSession s, CloseStatus status) {
        Conexion c = sesiones.get(s.getId());
        sesiones.quitar(s.getId());
        if (c != null && presencia.desconectar(c.usuario().id(), s.getId())) {
            bus.efimero("presencia", "presencia.actualizada",
                    PresenciaService.evento(c.usuario().id(), c.usuario().nombre(), false), null);
        }
    }

    /** D-1.4: el socket no sobrevive al token con el que se emitio el ticket. */
    @Scheduled(fixedDelay = 15_000)
    public void cerrarVencidos() {
        Instant ahora = Instant.now();
        for (Conexion c : sesiones.todas()) {
            if (c.usuario().expira() != null && c.usuario().expira().isBefore(ahora)) {
                try {
                    c.socket().close(new CloseStatus(CLOSE_TOKEN_EXPIRED, "token"));
                } catch (IOException ignored) {
                    // ya cerrado
                }
            }
        }
    }

    private void suscribir(Conexion c, String topic, long afterSeq) {
        if (topic == null || !puede(c.usuario(), topic)) {
            error(c, topic, topic == null ? "bad-request" : "forbidden");
            return;
        }
        c.topicos().add(topic);
        long actual = bus.seqActual(topic);
        if (afterSeq < 0) {
            sesiones.enviar(c, objeto("subscribed", topic, actual));
            return;
        }
        List<JsonNode> faltan = bus.desde(topic, afterSeq);
        if (faltan == null) {
            sesiones.enviar(c, objeto("resync", topic, actual));
            return;
        }
        for (JsonNode ev : faltan) sesiones.enviar(c, ev.toString());
    }

    private void efimero(Conexion c, String topic, String event) {
        // Solo "escribiendo" en un canal propio; el resto se ignora.
        if (topic == null || !topic.startsWith("canal:") || !"escribiendo".equals(event) || !puede(c.usuario(), topic)) {
            return;
        }
        String clave = "comms:escribiendo:" + topic + ":" + c.usuario().id();
        Boolean nuevo = redis.opsForValue().setIfAbsent(clave, "1", ESCRIBIENDO_MIN);
        if (!Boolean.TRUE.equals(nuevo)) return;
        bus.efimero(topic, "escribiendo", Map.of("usuarioId", c.usuario().id(), "nombre", c.usuario().nombre()),
                c.usuario().sub());
    }

    boolean puede(Usuario u, String topic) {
        if (topic.equals("presencia")) return true;
        if (topic.startsWith("user:")) return topic.equals("user:" + u.sub());
        if (topic.startsWith("canal:")) {
            try {
                return chat.esMiembroActivo(Long.parseLong(topic.substring(6)), u.id());
            } catch (NumberFormatException e) {
                return false;
            }
        }
        return false;
    }

    private void error(Conexion c, String topic, String code) {
        ObjectNode e = json.createObjectNode().put("type", "error").put("code", code);
        if (topic != null) e.put("topic", topic);
        sesiones.enviar(c, e.toString());
    }

    private String objeto(String type, String topic, long seq) {
        return json.createObjectNode().put("type", type).put("topic", topic).put("seq", seq).toString();
    }

    static String ticketDe(URI uri) {
        if (uri == null || uri.getQuery() == null) return null;
        for (String p : uri.getQuery().split("&")) {
            if (p.startsWith("ticket=")) return p.substring(7);
        }
        return null;
    }
}
