package com.co.eurekatic.aicontrol.agente.memoria;

import com.co.eurekatic.aicontrol.agente.persistencia.MensajeRepository;
import com.co.eurekatic.aicontrol.config.AgenteProperties;
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
import java.util.UUID;

/**
 * Memoria de conversacion en Redis, clave {@code ai:mem:{conversationId}}, con
 * TTL desde {@link AgenteProperties#memoriaTtl()}.
 *
 * <p>Si la clave no existe (expiro o nunca se escribio), la memoria se
 * reconstruye desde {@code ai.mensaje}, solo con los turnos de texto. Si Redis
 * no responde, la lectura devuelve vacio y se registra un WARN sin contenido:
 * la memoria es una optimizacion y la verdad esta en la base.
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
    private final AgenteProperties props;
    private final MensajeRepository mensajes;

    public RedisChatMemoryRepository(StringRedisTemplate redis, JsonMapper json, AgenteProperties props,
                                     MensajeRepository mensajes) {
        this.redis = redis;
        this.json = json;
        this.props = props;
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
            log.warn("Memoria del agente no disponible al listar conversaciones: {}", e.getClass().getSimpleName());
            return new ArrayList<>();
        }
    }

    @Override
    public List<Message> findByConversationId(String conversationId) {
        String crudo;
        try {
            crudo = redis.opsForValue().get(clave(conversationId));
        } catch (RuntimeException e) {
            log.warn("Memoria del agente no disponible al leer: {}", e.getClass().getSimpleName());
            return new ArrayList<>();
        }
        if (crudo == null) {
            return reconstruir(conversationId);
        }
        try {
            List<Message> mensajes = new ArrayList<>();
            for (MensajeMemoria d : json.readValue(crudo, TIPO_LISTA)) {
                mensajes.add(MensajeMemoriaMapper.a(d));
            }
            return mensajes;
        } catch (RuntimeException e) {
            log.warn("Memoria del agente ilegible; se reconstruye desde la base: {}", e.getClass().getSimpleName());
            return reconstruir(conversationId);
        }
    }

    /** Reemplaza la memoria completa de la conversacion y renueva su TTL. */
    @Override
    public void saveAll(String conversationId, List<Message> messages) {
        List<MensajeMemoria> dtos = messages.stream().map(MensajeMemoriaMapper::desde).toList();
        try {
            redis.opsForValue().set(clave(conversationId), json.writeValueAsString(dtos), props.memoriaTtl());
        } catch (RuntimeException e) {
            log.warn("Memoria del agente no disponible al escribir: {}", e.getClass().getSimpleName());
        }
    }

    @Override
    public void deleteByConversationId(String conversationId) {
        try {
            redis.delete(clave(conversationId));
        } catch (RuntimeException e) {
            log.warn("Memoria del agente no disponible al borrar: {}", e.getClass().getSimpleName());
        }
    }

    /**
     * Memoria desde {@code ai.mensaje}: solo USER y ASSISTANT, en orden. Las
     * llamadas a herramientas intermedias no se reconstruyen.
     */
    List<Message> reconstruir(String conversationId) {
        List<Message> resultado = new ArrayList<>();
        try {
            for (MensajeRepository.Mensaje fila : mensajes.listarFinales(UUID.fromString(conversationId))) {
                MensajeMemoria.TipoMensaje tipo = MensajeMemoria.TipoMensaje.valueOf(fila.rol());
                resultado.add(MensajeMemoriaMapper.a(new MensajeMemoria(tipo, fila.contenido(), null, null)));
            }
        } catch (RuntimeException e) {
            log.warn("No se pudo reconstruir la memoria desde la base: {}", e.getClass().getSimpleName());
            return new ArrayList<>();
        }
        return resultado;
    }

    static String clave(String conversationId) {
        return PREFIJO + conversationId;
    }
}
