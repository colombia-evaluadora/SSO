package com.co.eurekatic.comms.outbox;

import com.co.eurekatic.comms.config.CommsProperties;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.AmqpException;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionTemplate;

import java.sql.Array;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Publica {@code comunicaciones.toutbox_evento} (V561) al exchange
 * {@code notifications}, routing key {@code evento} (notification-service).
 *
 * <p>{@code FOR UPDATE SKIP LOCKED}: varias replicas reparten el trabajo sin
 * publicar dos veces el mismo lote. Si RabbitMQ falla se suma un intento y se
 * reintenta en la siguiente pasada (hasta {@value #MAX_INTENTOS}); un duplicado
 * por caida entre publicar y marcar lo absorbe el {@code dedupeKey}.
 */
@Component
public class OutboxPublicador {

    static final int MAX_INTENTOS = 20;
    private static final int LOTE = 100;
    private static final Logger log = LoggerFactory.getLogger(OutboxPublicador.class);
    private static final TypeReference<Map<String, Object>> MAPA = new TypeReference<>() { };

    private final JdbcClient jdbc;
    private final RabbitTemplate rabbit;
    private final ObjectMapper json;
    private final TransactionTemplate tx;
    private final CommsProperties props;

    public OutboxPublicador(JdbcClient jdbc, RabbitTemplate rabbit, ObjectMapper json, TransactionTemplate tx,
                            CommsProperties props) {
        this.jdbc = jdbc;
        this.rabbit = rabbit;
        this.json = json;
        this.tx = tx;
        this.props = props;
    }

    @Scheduled(fixedDelayString = "${comms.outbox.intervalo-ms:1000}")
    public void publicarPendientes() {
        Integer publicados;
        do {
            publicados = tx.execute(s -> lote());
        } while (publicados != null && publicados == LOTE);
    }

    /** Purga diaria de lo ya publicado hace mas de 7 dias. */
    @Scheduled(cron = "${comms.outbox.purga-cron:0 15 4 * * *}", zone = "America/Bogota")
    public void purgar() {
        jdbc.sql("""
                DELETE FROM comunicaciones.toutbox_evento
                 WHERE publicado_en < NOW() - INTERVAL '7 days'""").update();
    }

    int lote() {
        List<Map<String, Object>> filas = jdbc.sql("""
                SELECT pk_toutbox_evento, tipo, destinatarios, titulo, cuerpo, deep_link, datos::text AS datos,
                       dedupe_key, agrupacion_key, actor, prioridad, app
                  FROM comunicaciones.toutbox_evento
                 WHERE publicado_en IS NULL AND intentos < :max
                 ORDER BY pk_toutbox_evento
                 LIMIT :lote
                 FOR UPDATE SKIP LOCKED""")
                .param("max", MAX_INTENTOS).param("lote", LOTE)
                .query((rs, n) -> {
                    Map<String, Object> ev = new LinkedHashMap<>();
                    ev.put("_pk", rs.getLong("pk_toutbox_evento"));
                    ev.put("tipo", rs.getString("tipo"));
                    Array dest = rs.getArray("destinatarios");
                    ev.put("destinatarios", dest == null ? List.of() : Arrays.asList((Object[]) dest.getArray()));
                    ev.put("app", rs.getString("app"));
                    ev.put("titulo", rs.getString("titulo"));
                    ev.put("cuerpo", rs.getString("cuerpo"));
                    ev.put("deepLink", rs.getString("deep_link"));
                    ev.put("datos", leer(rs.getString("datos")));
                    ev.put("dedupeKey", rs.getString("dedupe_key"));
                    ev.put("agrupacionKey", rs.getString("agrupacion_key"));
                    ev.put("actor", rs.getString("actor"));
                    ev.put("prioridad", rs.getString("prioridad"));
                    return ev;
                }).list();
        for (Map<String, Object> ev : filas) {
            long pk = (Long) ev.remove("_pk");
            try {
                rabbit.convertAndSend(props.exchangeNotificaciones(), "evento", ev);
                jdbc.sql("UPDATE comunicaciones.toutbox_evento SET publicado_en = NOW() WHERE pk_toutbox_evento = :pk")
                        .param("pk", pk).update();
            } catch (AmqpException e) {
                log.warn("Outbox {}: no se pudo publicar ({})", pk, e.getMessage());
                jdbc.sql("""
                        UPDATE comunicaciones.toutbox_evento
                           SET intentos = intentos + 1, ultimo_error = left(:err, 500)
                         WHERE pk_toutbox_evento = :pk""")
                        .param("err", String.valueOf(e.getMessage())).param("pk", pk).update();
                return 0;
            }
        }
        return filas.size();
    }

    private Map<String, Object> leer(String s) {
        try {
            return s == null ? Map.of() : json.readValue(s, MAPA);
        } catch (Exception e) {
            return Map.of();
        }
    }
}
