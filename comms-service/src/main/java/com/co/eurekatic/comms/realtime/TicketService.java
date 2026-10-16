package com.co.eurekatic.comms.realtime;

import com.co.eurekatic.comms.config.CommsProperties;
import com.co.eurekatic.comms.security.Usuario;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Service;

import java.security.SecureRandom;
import java.util.HexFormat;

/**
 * Ticket de un solo uso para abrir el socket (D-1.2): 256 bits aleatorios en
 * Redis con TTL corto; el handshake lo consume con GETDEL. El JWT nunca viaja
 * en la URL ni queda en logs.
 */
@Service
public class TicketService {

    private static final SecureRandom RANDOM = new SecureRandom();

    private final StringRedisTemplate redis;
    private final ObjectMapper json;
    private final CommsProperties props;

    public TicketService(StringRedisTemplate redis, ObjectMapper json, CommsProperties props) {
        this.redis = redis;
        this.json = json;
        this.props = props;
    }

    public record Ticket(String ticket, long expiresIn) { }

    public Ticket emitir(Usuario u) {
        byte[] b = new byte[32];
        RANDOM.nextBytes(b);
        String t = HexFormat.of().formatHex(b);
        try {
            redis.opsForValue().set(clave(t), json.writeValueAsString(u), props.ticketTtl());
        } catch (JsonProcessingException e) {
            throw new IllegalStateException(e);
        }
        return new Ticket(t, props.ticketTtl().toSeconds());
    }

    /** @return el usuario del ticket, o null si no existe, ya se uso o vencio. */
    public Usuario consumir(String ticket) {
        if (ticket == null || !ticket.matches("[0-9a-f]{64}")) return null;
        String v = redis.opsForValue().getAndDelete(clave(ticket));
        if (v == null) return null;
        try {
            return json.readValue(v, Usuario.class);
        } catch (JsonProcessingException e) {
            return null;
        }
    }

    private static String clave(String t) {
        return "comms:ticket:" + t;
    }
}
