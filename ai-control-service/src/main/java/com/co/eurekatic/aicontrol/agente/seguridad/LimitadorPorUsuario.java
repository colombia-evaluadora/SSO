package com.co.eurekatic.aicontrol.agente.seguridad;

import com.co.eurekatic.aicontrol.config.AgenteProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

import java.time.Duration;

/**
 * Turnos por minuto y por usuario, con un contador en Redis por ventana de
 * minuto: {@code ai:rl:{userId}:{epochMinute}}.
 *
 * <p>Redis es opcional para el agente: si no responde, el turno se permite y
 * se deja un WARN sin datos. Quien llama convierte un {@code false} en 429.
 */
@Component
public class LimitadorPorUsuario {

    private static final Logger log = LoggerFactory.getLogger(LimitadorPorUsuario.class);
    static final String PREFIJO = "ai:rl:";
    private static final Duration VENTANA = Duration.ofSeconds(60);

    private final StringRedisTemplate redis;
    private final AgenteProperties props;

    public LimitadorPorUsuario(StringRedisTemplate redis, AgenteProperties props) {
        this.redis = redis;
        this.props = props;
    }

    /**
     * @return true si el turno cabe en el cupo del minuto actual
     */
    public boolean permitir(long userId) {
        String clave = PREFIJO + userId + ":" + System.currentTimeMillis() / VENTANA.toMillis();
        try {
            Long turnos = redis.opsForValue().increment(clave);
            redis.expire(clave, VENTANA);
            return turnos == null || turnos <= props.rateLimitUsuarioPorMin();
        } catch (RuntimeException e) {
            log.warn("Limitador por usuario no disponible; se permite el turno: {}", e.getClass().getSimpleName());
            return true;
        }
    }
}
