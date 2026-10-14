package com.co.eurekatic.aicontrol.agente.seguridad.seudonimos;

import com.co.eurekatic.aicontrol.config.agente.AgenteProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

/**
 * Tabla de seudonimos en un hash de Redis por conversacion ({@code ai:seud:{id}}, alias a nombre), con el
 * TTL de la memoria. Si Redis no responde, la tabla del turno empieza vacia: los nombres siguen saliendo
 * con alias, solo que la numeracion no se conserva entre turnos.
 */
@Component
public class AlmacenSeudonimosRedis implements AlmacenSeudonimos {

    static final String PREFIJO = "ai:seud:";
    private static final Logger log = LoggerFactory.getLogger(AlmacenSeudonimosRedis.class);

    private final StringRedisTemplate redis;
    private final Duration ttl;

    public AlmacenSeudonimosRedis(StringRedisTemplate redis, AgenteProperties props) {
        this.redis = redis;
        this.ttl = props.memoria().ttl();
    }

    @Override
    public TablaSeudonimos cargar(UUID conversacionId) {
        try {
            Map<String, String> guardados = new HashMap<>();
            redis.opsForHash().entries(clave(conversacionId))
                    .forEach((k, v) -> guardados.put(String.valueOf(k), String.valueOf(v)));
            return TablaSeudonimos.desde(guardados);
        } catch (RuntimeException e) {
            log.warn("Seudonimos no disponibles al leer: {}", e.getClass().getSimpleName());
            return TablaSeudonimos.vacia();
        }
    }

    @Override
    public void guardar(UUID conversacionId, TablaSeudonimos tabla) {
        Map<String, String> nuevos = tabla.nuevos();
        if (nuevos.isEmpty()) {
            return;
        }
        try {
            redis.opsForHash().putAll(clave(conversacionId), nuevos);
            redis.expire(clave(conversacionId), ttl);
        } catch (RuntimeException e) {
            log.warn("Seudonimos no disponibles al escribir: {}", e.getClass().getSimpleName());
        }
    }

    static String clave(UUID conversacionId) {
        return PREFIJO + conversacionId;
    }
}
