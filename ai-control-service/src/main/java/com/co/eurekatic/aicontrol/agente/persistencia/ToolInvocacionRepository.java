package com.co.eurekatic.aicontrol.agente.persistencia;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/**
 * Registro de cada llamada a herramienta de un turno, en {@code ai.tool_invocacion}.
 */
@Repository
public class ToolInvocacionRepository {

    private final JdbcClient jdbc;

    public ToolInvocacionRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    /** Resultado de la invocacion, tal como lo guarda la tabla. */
    public enum Estado { OK, ERROR, RECHAZADA, PENDIENTE, LIMITE }

    /**
     * Datos de una invocacion. {@code argumentosJson} y {@code resultadoResumen}
     * llegan ya saneados por quien invoca: aqui no se filtra nada.
     */
    public record NuevaInvocacion(long mensajeId, Long herramientaId, String nombre, String argumentosJson,
                                  Estado estado, Integer httpStatus, String resultadoResumen,
                                  Integer duracionMs) {
    }

    /** @return id de la invocacion insertada */
    public long insertar(NuevaInvocacion inv) {
        return jdbc.sql("""
                        INSERT INTO ai.tool_invocacion (mensaje_id, herramienta_id, nombre, argumentos, estado,
                                                        http_status, resultado_resumen, duracion_ms, created_by)
                        VALUES (:mensajeId, :herramientaId, :nombre, CAST(:argumentos AS jsonb), :estado,
                                :httpStatus, :resultadoResumen, :duracionMs, :actor)
                        RETURNING id
                        """)
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
