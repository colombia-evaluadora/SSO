package com.co.eurekatic.aicontrol.agente.nucleo.borrador;

import com.co.eurekatic.aicontrol.config.agente.AgenteProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;
import tools.jackson.databind.json.JsonMapper;

import java.time.Duration;
import java.util.Optional;
import java.util.UUID;

/**
 * El borrador de cada conversacion en Redis ({@code ai:borr:{id}}, JSON), con el TTL de la memoria. Se borra al
 * confirmar con exito o al cancelar. Si Redis no responde, el turno sigue sin borrador: el modelo vuelve a
 * consultar, como antes.
 */
@Component
public class BorradoresAccion {

    static final String PREFIJO = "ai:borr:";
    private static final Logger log = LoggerFactory.getLogger(BorradoresAccion.class);

    private final StringRedisTemplate redis;
    private final Duration ttl;
    private final JsonMapper json = JsonMapper.builder().build();

    public BorradoresAccion(StringRedisTemplate redis, AgenteProperties props) {
        this.redis = redis;
        this.ttl = props.memoria().ttl();
    }

    public Optional<BorradorAccion> cargar(UUID conversacionId) {
        try {
            String guardado = redis.opsForValue().get(clave(conversacionId));
            return guardado == null ? Optional.empty() : Optional.of(json.readValue(guardado, BorradorAccion.class));
        } catch (RuntimeException e) {
            log.warn("Borrador no disponible al leer: {}", e.getClass().getSimpleName());
            return Optional.empty();
        }
    }

    /** Guarda el intento del turno encima del anterior ({@link BorradorAccion#seguidoDe}). */
    public void guardar(UUID conversacionId, Optional<BorradorAccion> anterior, BorradorAccion intento) {
        BorradorAccion junto = anterior.map(a -> a.seguidoDe(intento)).orElse(intento);
        try {
            redis.opsForValue().set(clave(conversacionId), json.writeValueAsString(junto), ttl);
        } catch (RuntimeException e) {
            log.warn("Borrador no disponible al escribir: {}", e.getClass().getSimpleName());
        }
    }

    public void borrar(UUID conversacionId) {
        try {
            redis.delete(clave(conversacionId));
        } catch (RuntimeException e) {
            log.warn("Borrador no disponible al borrar: {}", e.getClass().getSimpleName());
        }
    }

    static String clave(UUID conversacionId) {
        return PREFIJO + conversacionId;
    }
}
