package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.config.agente.AgenteProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.util.LinkedHashSet;
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
        Set<String> ids = new LinkedHashSet<>(ExtractorIds.extraer(filas));
        ExtractorIds.extraerTipados(filas).forEach(tipado -> {
            int igual = tipado.indexOf('=');
            ids.add(tipado(tipado.substring(0, igual), tipado.substring(igual + 1)));
            ids.add(marca(tipado.substring(0, igual)));
            ids.add(conEntidad(tipado.substring(igual + 1)));
        });
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
    public Presencia consultar(String conversationId, String id) {
        try {
            return Boolean.TRUE.equals(redis.opsForSet().isMember(clave(conversationId), id))
                    ? Presencia.VISTO
                    : Presencia.NO_VISTO;
        } catch (RuntimeException e) {
            log.warn("Registro de ids no disponible al leer: {}", e.getClass().getSimpleName());
            return Presencia.DESCONOCIDO;
        }
    }

    @Override
    public Presencia consultarDe(String conversationId, String entidad, String id) {
        try {
            Map<Object, Boolean> miembros = redis.opsForSet().isMember(clave(conversationId),
                    marca(entidad), tipado(entidad, id), conEntidad(id), id);
            if (miembros == null) {
                return Presencia.DESCONOCIDO;
            }
            return decidir(Boolean.TRUE.equals(miembros.get(id)),
                    Boolean.TRUE.equals(miembros.get(tipado(entidad, id))),
                    Boolean.TRUE.equals(miembros.get(marca(entidad))),
                    Boolean.TRUE.equals(miembros.get(conEntidad(id))));
        } catch (RuntimeException e) {
            log.warn("Registro de ids no disponible al leer: {}", e.getClass().getSimpleName());
            return Presencia.DESCONOCIDO;
        }
    }

    /**
     * Solo se rechaza lo que se vio como otra cosa: hay ids de la entidad, este no es uno de ellos y si salio con
     * otra entidad (el pk de un grado puesto como grupo). Si no, cuenta la presencia sin tipo: un id puede llegar
     * en una columna que no nombra su entidad.
     */
    static Presencia decidir(boolean visto, boolean vistoComoEntidad, boolean entidadVista, boolean vistoConOtraEntidad) {
        if (vistoComoEntidad) {
            return Presencia.VISTO;
        }
        if (entidadVista && vistoConOtraEntidad) {
            return Presencia.NO_VISTO;
        }
        return visto ? Presencia.VISTO : Presencia.NO_VISTO;
    }

    static String conEntidad(String id) {
        return "o:" + id;
    }

    /** Miembros del mismo set: los tipados llevan prefijo, asi no chocan con un id de texto. */
    static String tipado(String entidad, String id) {
        return "e:" + entidad + ":" + id;
    }

    static String marca(String entidad) {
        return "t:" + entidad;
    }

    static String clave(String conversationId) {
        return PREFIJO + conversationId;
    }
}
