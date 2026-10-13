package com.co.eurekatic.aicontrol.agente.persistencia;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.util.List;

/**
 * Consultas analiticas del agente, en {@code ai.consulta_analitica}: una fila
 * por ejecucion, enlazada al mensaje que la pidio.
 */
@Repository
public class ConsultaAnaliticaRepository {

    private final JdbcClient jdbc;

    public ConsultaAnaliticaRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    /** Resultado de la consulta. */
    public enum Estado { OK, RECHAZADA, ERROR, TIMEOUT }

    /**
     * Datos de una consulta. {@code nivel} 1 es consulta curada y 2 es SQL
     * generado; {@code sqlHash} se usa cuando no se guarda el texto.
     */
    public record NuevaConsulta(long mensajeId, int nivel, String sqlTexto, String sqlHash, List<String> vistas,
                                Integer filas, Integer duracionMs, Estado estado, String motivo) {
    }

    /** @return id de la consulta insertada */
    public long insertar(NuevaConsulta c) {
        String[] vistas = c.vistas() == null ? null : c.vistas().toArray(String[]::new);
        return jdbc.sql("""
                        INSERT INTO ai.consulta_analitica (mensaje_id, nivel, sql_texto, sql_hash, vistas, filas,
                                                           duracion_ms, estado, motivo, created_by)
                        VALUES (:mensajeId, :nivel, :sqlTexto, :sqlHash, CAST(:vistas AS text[]), :filas,
                                :duracionMs, :estado, :motivo, :actor)
                        RETURNING id
                        """)
                .param("mensajeId", c.mensajeId())
                .param("nivel", c.nivel())
                .param("sqlTexto", c.sqlTexto())
                .param("sqlHash", c.sqlHash())
                .param("vistas", vistas)
                .param("filas", c.filas())
                .param("duracionMs", c.duracionMs())
                .param("estado", c.estado().name())
                .param("motivo", c.motivo())
                .param("actor", Auditoria.ACTOR)
                .query(Long.class)
                .single();
    }
}
