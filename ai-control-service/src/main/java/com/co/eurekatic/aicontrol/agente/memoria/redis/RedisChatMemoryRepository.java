package com.co.eurekatic.aicontrol.agente.memoria.redis;

import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoriaMapper;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore;
import com.co.eurekatic.aicontrol.config.agente.AgenteProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.chat.memory.ChatMemoryRepository;
import org.springframework.ai.chat.messages.Message;
import org.springframework.data.redis.core.Cursor;
import org.springframework.data.redis.core.ScanOptions;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;
import tools.jackson.core.type.TypeReference;
import tools.jackson.databind.json.JsonMapper;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * Memoria de conversacion en Redis, clave {@code ai:mem:{conversationId}}, con
 * TTL desde {@link AgenteProperties.Memoria}.
 *
 * <p>Si la clave no existe (expiro o nunca se escribio), o no se puede leer, la
 * memoria se reconstruye desde {@code ai.mensaje}, solo con los turnos de texto.
 * Si Redis no responde, la lectura devuelve vacio: la memoria es una
 * optimizacion y la verdad esta en la base.
 *
 * <p>Los logs llevan solo el tipo de error, nunca el contenido de los mensajes.
 */
@Component
public class RedisChatMemoryRepository implements ChatMemoryRepository {

    private static final Logger log = LoggerFactory.getLogger(RedisChatMemoryRepository.class);
    static final String PREFIJO = "ai:mem:";
    private static final TypeReference<List<MensajeMemoria>> TIPO_LISTA = new TypeReference<>() {};

    private final StringRedisTemplate redis;
    private final JsonMapper json;
    private final AgenteProperties.Memoria props;
    private final MensajeStore mensajes;

    public RedisChatMemoryRepository(StringRedisTemplate redis, JsonMapper json, AgenteProperties props,
                                     MensajeStore mensajes) {
        this.redis = redis;
        this.json = json;
        this.props = props.memoria();
        this.mensajes = mensajes;
    }

    /** Ids de conversacion con memoria viva. Usa SCAN, nunca KEYS, para no bloquear Redis. */
    @Override
    public List<String> findConversationIds() {
        ScanOptions opciones = ScanOptions.scanOptions().match(PREFIJO + "*").count(100).build();
        List<String> ids = new ArrayList<>();
        try (Cursor<String> cursor = redis.scan(opciones)) {
            while (cursor.hasNext()) {
                ids.add(cursor.next().substring(PREFIJO.length()));
            }
            return ids;
        } catch (RuntimeException e) {
            advertir("no disponible al listar conversaciones", e);
            return new ArrayList<>();
        }
    }

    @Override
    public List<Message> findByConversationId(String conversationId) {
        String crudo;
        try {
            crudo = redis.opsForValue().get(clave(conversationId));
        } catch (RuntimeException e) {
            advertir("no disponible al leer; se reconstruye desde la base", e);
            return reconstruir(conversationId);
        }
        if (crudo == null) {
            return reconstruir(conversationId);
        }
        return decodificar(crudo).orElseGet(() -> reconstruir(conversationId));
    }

    /** Reemplaza la memoria completa de la conversacion y renueva su TTL. */
    @Override
    public void saveAll(String conversationId, List<Message> messages) {
        List<MensajeMemoria> turnos = messages.stream().map(MensajeMemoriaMapper::desde).toList();
        try {
            String cuerpo = json.writerFor(TIPO_LISTA).writeValueAsString(turnos);
            redis.opsForValue().set(clave(conversationId), cuerpo, props.ttl());
        } catch (RuntimeException e) {
            advertir("no disponible al escribir", e);
        }
    }

    @Override
    public void deleteByConversationId(String conversationId) {
        try {
            redis.delete(clave(conversationId));
        } catch (RuntimeException e) {
            advertir("no disponible al borrar", e);
        }
    }

    /** Lee la clave; vacio si su contenido no se puede decodificar. */
    private Optional<List<Message>> decodificar(String crudo) {
        try {
            List<Message> resultado = new ArrayList<>();
            for (MensajeMemoria turno : json.readValue(crudo, TIPO_LISTA)) {
                resultado.add(MensajeMemoriaMapper.a(turno));
            }
            return Optional.of(resultado);
        } catch (RuntimeException e) {
            advertir("ilegible; se reconstruye desde la base", e);
            return Optional.empty();
        }
    }

    /**
     * Memoria desde {@code ai.mensaje}: solo USER y ASSISTANT, en orden. Las
     * llamadas a herramientas intermedias no se reconstruyen.
     */
    List<Message> reconstruir(String conversationId) {
        try {
            List<Message> resultado = new ArrayList<>();
            for (MensajeStore.Mensaje fila : mensajes.listarFinales(UUID.fromString(conversationId))) {
                resultado.add(MensajeMemoriaMapper.a(MensajeMemoriaMapper.desdeTurno(fila)));
            }
            return resultado;
        } catch (RuntimeException e) {
            advertir("no se pudo reconstruir desde la base", e);
            return new ArrayList<>();
        }
    }

    static String clave(String conversationId) {
        return PREFIJO + conversationId;
    }

    private static void advertir(String situacion, RuntimeException e) {
        log.warn("Memoria del agente {}: {}", situacion, e.getClass().getSimpleName());
    }
}
