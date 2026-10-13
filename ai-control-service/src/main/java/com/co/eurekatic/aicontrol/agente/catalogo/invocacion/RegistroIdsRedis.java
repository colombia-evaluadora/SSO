package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.config.agente.AgenteProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Adaptador Redis de {@link RegistroIds}: un set por conversacion, {@code ai:ids:{conversationId}},
 * con el TTL de la memoria. Los logs no llevan valores, solo el tipo de error.
 */
@Component
public class RegistroIdsRedis implements RegistroIds {

    private static final Logger log = LoggerFactory.getLogger(RegistroIdsRedis.class);
    static final String PREFIJO = "ai:ids:";

    private final StringRedisTemplate redis;
    private final Duration ttl;

    public RegistroIdsRedis(StringRedisTemplate redis, AgenteProperties props) {
        this.redis = redis;
        this.ttl = props.memoria().ttl();
    }

    @Override
    public void registrar(String conversationId, List<Map<String, Object>> filas) {
        Set<String> ids = ExtractorIds.extraer(filas);
        if (ids.isEmpty()) {
            return;
        }
        String clave = clave(conversationId);
        try {
            redis.opsForSet().add(clave, ids.toArray(String[]::new));
            redis.expire(clave, ttl);
        } catch (RuntimeException e) {
            log.warn("Registro de ids no disponible al escribir: {}", e.getClass().getSimpleName());
        }
    }

    @Override
    public boolean contiene(String conversationId, String id) {
        try {
            return Boolean.TRUE.equals(redis.opsForSet().isMember(clave(conversationId), id));
        } catch (RuntimeException e) {
            log.warn("Registro de ids no disponible al leer; se permite el valor: {}", e.getClass().getSimpleName());
            return true;
        }
    }

    static String clave(String conversationId) {
        return PREFIJO + conversationId;
    }
}
