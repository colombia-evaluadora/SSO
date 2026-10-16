package com.co.eurekatic.comms.realtime;

import com.co.eurekatic.comms.config.CommsProperties;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Service;

import java.util.Collection;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/**
 * Presencia: un ZSET {@code comms:presencia} con miembro {@code <userId>:<socketId>}
 * y puntaje = ultimo latido. En linea = algun socket con latido dentro de
 * {@code comms.presencia-ttl}. Una replica caida deja de contar sola al vencer.
 */
@Service
public class PresenciaService {

    static final String CLAVE = "comms:presencia";

    private final StringRedisTemplate redis;
    private final CommsProperties props;

    public PresenciaService(StringRedisTemplate redis, CommsProperties props) {
        this.redis = redis;
        this.props = props;
    }

    /** @return true si el usuario no tenia ningun socket vivo (paso a en linea). */
    public boolean latido(long userId, String socketId) {
        boolean antes = enLinea(Set.of(userId)).contains(userId);
        redis.opsForZSet().add(CLAVE, userId + ":" + socketId, System.currentTimeMillis());
        return !antes;
    }

    /** @return true si era su ultimo socket (paso a desconectado). */
    public boolean desconectar(long userId, String socketId) {
        redis.opsForZSet().remove(CLAVE, userId + ":" + socketId);
        return !enLinea(Set.of(userId)).contains(userId);
    }

    public Set<Long> enLinea(Collection<Long> usuarios) {
        long desde = System.currentTimeMillis() - props.presenciaTtl().toMillis();
        redis.opsForZSet().removeRangeByScore(CLAVE, 0, desde);
        Set<String> vivos = redis.opsForZSet().rangeByScore(CLAVE, desde, Double.POSITIVE_INFINITY);
        Set<Long> out = new HashSet<>();
        if (vivos == null) return out;
        for (String v : vivos) {
            long id = Long.parseLong(v.substring(0, v.indexOf(':')));
            if (usuarios.contains(id)) out.add(id);
        }
        return out;
    }

    public static Map<String, Object> evento(long userId, String nombre, boolean enLinea) {
        return Map.of("usuarioId", userId, "nombre", nombre == null ? "" : nombre, "enLinea", enLinea);
    }
}
