package com.co.eurekatic.aicontrol.agente.persistencia.herramienta;

import com.co.eurekatic.aicontrol.agente.persistencia.Auditoria;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

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
}
