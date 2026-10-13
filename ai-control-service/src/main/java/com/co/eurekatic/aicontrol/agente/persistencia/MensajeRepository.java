package com.co.eurekatic.aicontrol.agente.persistencia;

import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDateTime;
import java.util.List;
import java.util.UUID;

/**
 * Mensajes de una conversacion en {@code ai.mensaje}. El contenido llega ya
 * anonimizado: aqui no se sanea nada.
 */
@Repository
public class MensajeRepository {

    private static final String COLUMNAS =
            "id, conversacion_id, secuencia, rol, contenido, tipo_respuesta, acciones_ui, created_at";

    private static final RowMapper<Mensaje> FILA = (rs, n) -> new Mensaje(
            rs.getLong("id"),
            rs.getObject("conversacion_id", UUID.class),
            rs.getInt("secuencia"),
            rs.getString("rol"),
            rs.getString("contenido"),
            rs.getString("tipo_respuesta"),
            rs.getString("acciones_ui"),
            rs.getObject("created_at", LocalDateTime.class));

    private final JdbcClient jdbc;
    private final ConversacionRepository conversaciones;

    public MensajeRepository(JdbcClient jdbc, ConversacionRepository conversaciones) {
        this.jdbc = jdbc;
        this.conversaciones = conversaciones;
    }

    /** Fila de {@code ai.mensaje}. {@code rol}: USER, ASSISTANT, TOOL o SYSTEM. */
    public record Mensaje(long id, UUID conversacionId, int secuencia, String rol, String contenido,
                          String tipoRespuesta, String accionesUi, LocalDateTime createdAt) {
    }

    /**
     * Datos de un mensaje nuevo. {@code accionesUiJson} es JSON o null;
     * los tokens son null cuando el mensaje no vino del modelo.
     */
    public record NuevoMensaje(String rol, String contenido, String tipoRespuesta, String accionesUiJson,
                               String modelo, Integer tokensEntrada, Integer tokensSalida,
                               Integer tokensRazonamiento, Integer latenciaMs) {
    }

    /**
     * Inserta un mensaje con la siguiente secuencia de la conversacion y
     * actualiza su ultimo mensaje, todo en una transaccion.
     *
     * <p>La conversacion se bloquea con {@code FOR UPDATE} antes de calcular
     * el maximo: dos turnos simultaneos de la misma conversacion se serializan
     * en vez de chocar con {@code ux_ai_mensaje_secuencia}.
     *
     * @return id del mensaje insertado
     */
    @Transactional
    public long insertar(UUID conversacionId, NuevoMensaje m) {
        jdbc.sql("SELECT id FROM ai.conversacion WHERE id = :cid FOR UPDATE")
                .param("cid", conversacionId)
                .query(UUID.class)
                .single();

        long id = jdbc.sql("""
                        INSERT INTO ai.mensaje (conversacion_id, secuencia, rol, contenido, tipo_respuesta,
                                                acciones_ui, modelo, tokens_entrada, tokens_salida,
                                                tokens_razonamiento, latencia_ms, created_by)
                        VALUES (:cid,
                                (SELECT COALESCE(MAX(secuencia), 0) + 1 FROM ai.mensaje WHERE conversacion_id = :cid),
                                :rol, :contenido, :tipoRespuesta, CAST(:accionesUi AS jsonb), :modelo,
                                :tokensEntrada, :tokensSalida, :tokensRazonamiento, :latenciaMs, :actor)
                        RETURNING id
                        """)
                .param("cid", conversacionId)
                .param("rol", m.rol())
                .param("contenido", m.contenido())
                .param("tipoRespuesta", m.tipoRespuesta())
                .param("accionesUi", m.accionesUiJson())
                .param("modelo", m.modelo())
                .param("tokensEntrada", m.tokensEntrada())
                .param("tokensSalida", m.tokensSalida())
                .param("tokensRazonamiento", m.tokensRazonamiento())
                .param("latenciaMs", m.latenciaMs())
                .param("actor", Auditoria.ACTOR)
                .query(Long.class)
                .single();

        conversaciones.tocarUltimoMensaje(conversacionId);
        return id;
    }

    /** Todos los mensajes activos de la conversacion, en orden de secuencia. */
    public List<Mensaje> listar(UUID conversacionId) {
        return jdbc.sql("""
                        SELECT """ + COLUMNAS + """
                         FROM ai.mensaje
                        WHERE conversacion_id = :cid AND active = TRUE
                        ORDER BY secuencia
                        """)
                .param("cid", conversacionId)
                .query(FILA)
                .list();
    }

    /**
     * Solo los turnos de texto (USER y ASSISTANT), en orden. Es con lo que se
     * reconstruye la memoria cuando Redis ya no la tiene.
     */
    public List<Mensaje> listarFinales(UUID conversacionId) {
        return jdbc.sql("""
                        SELECT """ + COLUMNAS + """
                         FROM ai.mensaje
                        WHERE conversacion_id = :cid AND active = TRUE AND rol IN ('USER', 'ASSISTANT')
                        ORDER BY secuencia
                        """)
                .param("cid", conversacionId)
                .query(FILA)
                .list();
    }
}
