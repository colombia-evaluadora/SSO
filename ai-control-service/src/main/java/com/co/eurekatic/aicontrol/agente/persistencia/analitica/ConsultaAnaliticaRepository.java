package com.co.eurekatic.aicontrol.agente.persistencia.analitica;

import com.co.eurekatic.aicontrol.agente.persistencia.Auditoria;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/** Adaptador JDBC de {@link ConsultaAnaliticaStore} sobre {@code ai.consulta_analitica}. */
@Repository
public class ConsultaAnaliticaRepository implements ConsultaAnaliticaStore {

    private static final String SQL_INSERTAR = """
            INSERT INTO ai.consulta_analitica (mensaje_id, nivel, sql_texto, sql_hash, vistas, filas,
                                               duracion_ms, estado, motivo, created_by)
            VALUES (:mensajeId, :nivel, :sqlTexto, :sqlHash, CAST(:vistas AS text[]), :filas,
                    :duracionMs, :estado, :motivo, :actor)
            RETURNING id
            """;

    private final JdbcClient jdbc;

    public ConsultaAnaliticaRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    @Override
    public long insertar(NuevaConsulta c) {
        String[] vistas = c.vistas() == null ? null : c.vistas().toArray(String[]::new);
        return jdbc.sql(SQL_INSERTAR)
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
