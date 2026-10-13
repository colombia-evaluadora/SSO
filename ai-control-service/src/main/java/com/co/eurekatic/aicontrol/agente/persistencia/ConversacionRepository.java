package com.co.eurekatic.aicontrol.agente.persistencia;

import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

/** Adaptador JDBC de {@link ConversacionStore} sobre {@code ai.conversacion}. */
@Repository
public class ConversacionRepository implements ConversacionStore {

    private static final String COLUMNAS = "id, fk_usuario, titulo, estado, ultimo_mensaje_at, created_at";

    private static final String SQL_CREAR = """
            INSERT INTO ai.conversacion (id, fk_usuario, titulo, created_by)
            VALUES (:id, :fkUsuario, :titulo, :actor)
            RETURNING """ + COLUMNAS;

    private static final String SQL_BUSCAR = """
            SELECT """ + COLUMNAS + """
             FROM ai.conversacion
            WHERE id = :id AND fk_usuario = :fkUsuario AND active = TRUE
            """;

    private static final String SQL_LISTAR = """
            SELECT """ + COLUMNAS + """
             FROM ai.conversacion
            WHERE fk_usuario = :fkUsuario AND active = TRUE AND estado <> 'ARCHIVADA'
            ORDER BY ultimo_mensaje_at DESC, created_at DESC
            LIMIT :size OFFSET :offset
            """;

    private static final String SQL_ARCHIVAR = """
            UPDATE ai.conversacion
               SET estado = 'ARCHIVADA', modified_by = :actor, modified_at = LOCALTIMESTAMP
             WHERE id = :id AND fk_usuario = :fkUsuario AND active = TRUE
            """;

    private static final String SQL_TOCAR = """
            UPDATE ai.conversacion
               SET ultimo_mensaje_at = LOCALTIMESTAMP, modified_by = :actor, modified_at = LOCALTIMESTAMP
             WHERE id = :id
            """;

    private static final RowMapper<Conversacion> FILA = (rs, n) -> new Conversacion(
            rs.getObject("id", UUID.class),
            rs.getLong("fk_usuario"),
            rs.getString("titulo"),
            EstadoConversacion.valueOf(rs.getString("estado")),
            rs.getObject("ultimo_mensaje_at", LocalDateTime.class),
            rs.getObject("created_at", LocalDateTime.class));

    private final JdbcClient jdbc;

    public ConversacionRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    @Override
    public Conversacion crear(long fkUsuario, String titulo) {
        return jdbc.sql(SQL_CREAR)
                .param("id", UUID.randomUUID())
                .param("fkUsuario", fkUsuario)
                .param("titulo", titulo)
                .param("actor", Auditoria.ACTOR)
                .query(FILA)
                .single();
    }

    @Override
    public Optional<Conversacion> buscar(UUID id, long fkUsuario) {
        return jdbc.sql(SQL_BUSCAR)
                .param("id", id)
                .param("fkUsuario", fkUsuario)
                .query(FILA)
                .optional();
    }

    @Override
    public List<Conversacion> listar(long fkUsuario, int page, int size) {
        return jdbc.sql(SQL_LISTAR)
                .param("fkUsuario", fkUsuario)
                .param("size", size)
                .param("offset", (long) page * size)
                .query(FILA)
                .list();
    }

    @Override
    public boolean archivar(UUID id, long fkUsuario) {
        int filas = jdbc.sql(SQL_ARCHIVAR)
                .param("id", id)
                .param("fkUsuario", fkUsuario)
                .param("actor", Auditoria.ACTOR)
                .update();
        return filas == 1;
    }

    @Override
    public void tocarUltimoMensaje(UUID id) {
        jdbc.sql(SQL_TOCAR)
                .param("id", id)
                .param("actor", Auditoria.ACTOR)
                .update();
    }
}
