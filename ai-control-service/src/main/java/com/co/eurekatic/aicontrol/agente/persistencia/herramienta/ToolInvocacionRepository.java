package com.co.eurekatic.aicontrol.agente.persistencia.herramienta;

import com.co.eurekatic.aicontrol.agente.persistencia.Auditoria;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.util.List;
import java.util.UUID;

/** Adaptador JDBC de {@link ToolInvocacionStore} sobre {@code ai.tool_invocacion}. */
@Repository
public class ToolInvocacionRepository implements ToolInvocacionStore {

    private static final String SQL_INSERTAR = """
            INSERT INTO ai.tool_invocacion (mensaje_id, herramienta_id, nombre, argumentos, estado,
                                            http_status, resultado_resumen, duracion_ms, created_by)
            VALUES (:mensajeId, :herramientaId, :nombre, CAST(:argumentos AS jsonb), :estado,
                    :httpStatus, :resultadoResumen, :duracionMs, :actor)
            RETURNING id
            """;

    private static final String SQL_LISTAR = """
            SELECT t.id, t.mensaje_id, t.nombre, t.argumentos::text AS argumentos, t.resultado_resumen
              FROM ai.tool_invocacion t
              JOIN ai.mensaje m ON m.id = t.mensaje_id
             WHERE m.conversacion_id = :cid AND m.active = TRUE AND t.active = TRUE
             ORDER BY t.created_at, t.id
            """;

    private static final RowMapper<Invocacion> FILA = (rs, n) -> new Invocacion(
            rs.getLong("id"),
            rs.getLong("mensaje_id"),
            rs.getString("nombre"),
            rs.getString("argumentos"),
            rs.getString("resultado_resumen"));

    private final JdbcClient jdbc;

    public ToolInvocacionRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    @Override
    public long insertar(NuevaInvocacion inv) {
        return jdbc.sql(SQL_INSERTAR)
                .param("mensajeId", inv.mensajeId())
                .param("herramientaId", inv.herramientaId())
                .param("nombre", inv.nombre())
                .param("argumentos", inv.argumentosJson())
                .param("estado", inv.estado().name())
                .param("httpStatus", inv.httpStatus())
                .param("resultadoResumen", inv.resultadoResumen())
                .param("duracionMs", inv.duracionMs())
                .param("actor", Auditoria.ACTOR)
                .query(Long.class)
                .single();
    }

    @Override
    public List<Invocacion> listarPorConversacion(UUID conversacionId) {
        return jdbc.sql(SQL_LISTAR)
                .param("cid", conversacionId)
                .query(FILA)
                .list();
    }
}
