package com.co.eurekatic.comms.chat;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;

/**
 * Eventos de notificacion del chat. Se encolan en el outbox
 * ({@code comunicaciones.fn_outbox_evento_registrar_interno}, V561.1) y los
 * publica {@code OutboxPublicador}: si RabbitMQ esta caido, el aviso no se
 * pierde. Se llama tras el commit del mensaje; el mensaje ya es valido aunque
 * encolar fallara.
 */
@Component
public class NotificadorChat {

    private static final Logger log = LoggerFactory.getLogger(NotificadorChat.class);

    private final JdbcClient jdbc;
    private final ObjectMapper json;

    public NotificadorChat(JdbcClient jdbc, ObjectMapper json) {
        this.jdbc = jdbc;
        this.json = json;
    }

    public void enviar(String tipo, List<String> destinatarios, String titulo, String cuerpo, String deepLink,
                       Map<String, Object> datos, String dedupeKey, String agrupacionKey, String actor) {
        if (destinatarios.isEmpty()) return;
        try {
            jdbc.sql("""
                    SELECT comunicaciones.fn_outbox_evento_registrar_interno(
                        :tipo, CAST(:dest AS TEXT[]), :titulo, :cuerpo, :link, CAST(:datos AS JSONB),
                        :dedupe, :agrupacion, :actor, NULL)""")
                    .param("tipo", tipo).param("dest", arreglo(destinatarios)).param("titulo", titulo)
                    .param("cuerpo", cuerpo).param("link", deepLink)
                    .param("datos", json.writeValueAsString(datos == null ? Map.of() : datos))
                    .param("dedupe", dedupeKey).param("agrupacion", agrupacionKey).param("actor", actor)
                    .query((rs, n) -> 1).list();
        } catch (DataAccessException | JsonProcessingException e) {
            log.warn("No se pudo encolar la notificacion {}: {}", tipo, e.getMessage());
        }
    }

    /** Literal de arreglo de Postgres con cada elemento entre comillas. */
    static String arreglo(List<String> valores) {
        StringBuilder sb = new StringBuilder("{");
        for (int i = 0; i < valores.size(); i++) {
            if (i > 0) sb.append(',');
            sb.append('"').append(valores.get(i).replace("\\", "\\\\").replace("\"", "\\\"")).append('"');
        }
        return sb.append('}').toString();
    }
}
