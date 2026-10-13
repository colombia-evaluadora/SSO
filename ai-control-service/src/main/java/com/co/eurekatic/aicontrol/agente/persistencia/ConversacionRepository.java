package com.co.eurekatic.aicontrol.agente.persistencia;

import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/**
 * Conversaciones del agente en {@code ai.conversacion}. Toda consulta filtra
 * por dueño: una conversacion ajena no existe para quien la pide.
 */
@Repository
public class ConversacionRepository {

    private static final String COLUMNAS =
            "id, fk_usuario, titulo, estado, ultimo_mensaje_at, created_at";

    private static final RowMapper<Conversacion> FILA = (rs, n) -> new Conversacion(
            rs.getObject("id", UUID.class),
            rs.getLong("fk_usuario"),
            rs.getString("titulo"),
            rs.getString("estado"),
            rs.getObject("ultimo_mensaje_at", LocalDateTime.class),
            rs.getObject("created_at", LocalDateTime.class));

    private final JdbcClient jdbc;

    public ConversacionRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    /** Fila de {@code ai.conversacion}. {@code estado}: ACTIVA, ARCHIVADA o BLOQUEADA. */
    public record Conversacion(UUID id, long fkUsuario, String titulo, String estado,
                               LocalDateTime ultimoMensajeAt, LocalDateTime createdAt) {
    }

    /** Crea una conversacion con un id generado aqui, nunca recibido del cliente. */
    public Conversacion crear(long fkUsuario, String titulo) {
        return jdbc.sql("""
                        INSERT INTO ai.conversacion (id, fk_usuario, titulo, created_by)
                        VALUES (:id, :fkUsuario, :titulo, :actor)
                        RETURNING """ + COLUMNAS)
                .param("id", UUID.randomUUID())
                .param("fkUsuario", fkUsuario)
                .param("titulo", titulo)
                .param("actor", Auditoria.ACTOR)
                .query(FILA)
                .single();
    }

    public Optional<Conversacion> buscar(UUID id, long fkUsuario) {
        return jdbc.sql("""
                        SELECT """ + COLUMNAS + """
                         FROM ai.conversacion
                        WHERE id = :id AND fk_usuario = :fkUsuario AND active = TRUE
                        """)
                .param("id", id)
                .param("fkUsuario", fkUsuario)
                .query(FILA)
                .optional();
    }

    /**
     * Conversaciones del usuario que no estan archivadas, mas recientes primero.
     * Pagina basada en cero. El orden coincide con {@code ix_ai_conversacion_usuario}.
     */
    public List<Conversacion> listar(long fkUsuario, int page, int size) {
        return jdbc.sql("""
                        SELECT """ + COLUMNAS + """
                         FROM ai.conversacion
                        WHERE fk_usuario = :fkUsuario AND active = TRUE AND estado <> 'ARCHIVADA'
                        ORDER BY ultimo_mensaje_at DESC, created_at DESC
                        LIMIT :size OFFSET :offset
                        """)
                .param("fkUsuario", fkUsuario)
                .param("size", size)
                .param("offset", (long) page * size)
                .query(FILA)
                .list();
    }

    /** Archiva una conversacion propia. Devuelve false si no existe o no es del usuario. */
    public boolean archivar(UUID id, long fkUsuario) {
        int filas = jdbc.sql("""
                        UPDATE ai.conversacion
                           SET estado = 'ARCHIVADA', modified_by = :actor, modified_at = LOCALTIMESTAMP
                         WHERE id = :id AND fk_usuario = :fkUsuario AND active = TRUE
                        """)
                .param("id", id)
                .param("fkUsuario", fkUsuario)
                .param("actor", Auditoria.ACTOR)
                .update();
        return filas == 1;
    }

    /** Marca la hora del ultimo mensaje, que ordena el listado. Lo llama la insercion de mensajes. */
    public void tocarUltimoMensaje(UUID id) {
        jdbc.sql("""
                        UPDATE ai.conversacion
                           SET ultimo_mensaje_at = LOCALTIMESTAMP, modified_by = :actor, modified_at = LOCALTIMESTAMP
                         WHERE id = :id
                        """)
                .param("id", id)
                .param("actor", Auditoria.ACTOR)
                .update();
    }
}
