package com.co.eurekatic.comms.realtime;

import com.co.eurekatic.comms.config.CommsProperties;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.connection.Message;
import org.springframework.data.redis.connection.MessageListener;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;

/**
 * Bus de eventos de tiempo real (OpenSpec add-tiempo-real-gateway D-1.1/D-1.3).
 *
 * <ul>
 *   <li>Persistente: {@code seq} = INCR por topico; el evento se guarda en un
 *       ZSET acotado ({@code comms.historial} entradas) para {@code resume}.</li>
 *   <li>Efimero (escribiendo, presencia): sin seq ni historial.</li>
 *   <li>Fan-out entre replicas: PUBLISH al canal Redis {@code comms:rt}; cada
 *       replica lo entrega a sus sockets locales ({@link SesionesLocales}).</li>
 * </ul>
 */
@Component
public class RealtimeBus implements MessageListener {

    public static final String CANAL_REDIS = "comms:rt";
    private static final Logger log = LoggerFactory.getLogger(RealtimeBus.class);

    private final StringRedisTemplate redis;
    private final ObjectMapper json;
    private final CommsProperties props;
    private final SesionesLocales sesiones;

    public RealtimeBus(StringRedisTemplate redis, ObjectMapper json, CommsProperties props, SesionesLocales sesiones) {
        this.redis = redis;
        this.json = json;
        this.props = props;
        this.sesiones = sesiones;
    }

    /** Evento con seq. Devuelve el seq asignado (0 si Redis fallo: el WS no es fuente de verdad). */
    public long publicar(String topic, String event, Object data) {
        try {
            Long seq = redis.opsForValue().increment(claveSeq(topic));
            ObjectNode ev = evento(topic, event, data);
            ev.put("seq", seq);
            String txt = json.writeValueAsString(ev);
            String hist = claveHistorial(topic);
            redis.opsForZSet().add(hist, txt, seq);
            redis.opsForZSet().removeRange(hist, 0, -(props.historial() + 1L));
            redis.expire(hist, props.historialTtl());
            redis.expire(claveSeq(topic), props.historialTtl().multipliedBy(30));
            redis.convertAndSend(CANAL_REDIS, txt);
            return seq;
        } catch (RuntimeException | JsonProcessingException e) {
            log.warn("No se pudo publicar {} en {}: {}", event, topic, e.getMessage());
            return 0;
        }
    }

    /** Evento efimero; {@code exceptoSub} no lo recibe (quien escribe no se ve escribiendo). */
    public void efimero(String topic, String event, Object data, String exceptoSub) {
        try {
            ObjectNode ev = evento(topic, event, data);
            if (exceptoSub != null) ev.put("_excepto", exceptoSub);
            redis.convertAndSend(CANAL_REDIS, json.writeValueAsString(ev));
        } catch (RuntimeException | JsonProcessingException e) {
            log.debug("Efimero {} descartado: {}", event, e.getMessage());
        }
    }

    public long seqActual(String topic) {
        String v = redis.opsForValue().get(claveSeq(topic));
        return v == null ? 0 : Long.parseLong(v);
    }

    /**
     * Eventos con seq &gt; {@code despuesDe}, o null si el hueco ya no esta en el
     * historial (el cliente debe hacer resync por REST).
     */
    public List<JsonNode> desde(String topic, long despuesDe) {
        long actual = seqActual(topic);
        if (despuesDe >= actual) return List.of();
        Set<String> todos = redis.opsForZSet().rangeByScore(claveHistorial(topic), despuesDe + 1, Double.POSITIVE_INFINITY);
        List<JsonNode> out = new ArrayList<>();
        if (todos != null) {
            for (String s : todos) {
                try {
                    out.add(json.readTree(s));
                } catch (JsonProcessingException ignored) {
                    // entrada corrupta: se trata como hueco
                }
            }
        }
        if (out.isEmpty() || out.get(0).path("seq").asLong() != despuesDe + 1) return null;
        return out;
    }

    @Override
    public void onMessage(Message message, byte[] pattern) {
        try {
            JsonNode ev = json.readTree(message.getBody());
            String excepto = ev.path("_excepto").isMissingNode() ? null : ev.path("_excepto").asText();
            if (ev instanceof ObjectNode o) o.remove("_excepto");
            sesiones.entregar(ev.path("topic").asText(), ev, excepto);
        } catch (Exception e) {
            log.debug("Mensaje de tiempo real ilegible: {}", e.getMessage());
        }
    }

    private ObjectNode evento(String topic, String event, Object data) {
        ObjectNode ev = json.createObjectNode();
        ev.put("type", "event");
        ev.put("topic", topic);
        ev.put("event", event);
        ev.set("data", json.valueToTree(data));
        ev.put("at", Instant.now().toString());
        return ev;
    }

    private static String claveSeq(String topic) {
        return "comms:seq:" + topic;
    }

    private static String claveHistorial(String topic) {
        return "comms:hist:" + topic;
    }
}
