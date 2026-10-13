package com.co.eurekatic.aicontrol.agente.persistencia;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/** Adaptador JDBC de {@link EventoSeguridadStore} sobre {@code ai.evento_seguridad}. */
@Repository
public class EventoSeguridadRepository implements EventoSeguridadStore {

    private static final String SQL_INSERTAR = """
            INSERT INTO ai.evento_seguridad (conversacion_id, fk_usuario, capa, riesgo, motivo,
                                             fragmento_hash, created_by)
            VALUES (:cid, :fkUsuario, :capa, :riesgo, :motivo, :hash, :actor)
            RETURNING id
            """;

    private final JdbcClient jdbc;

    public EventoSeguridadRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    @Override
    public long insertar(NuevoEvento e) {
        return jdbc.sql(SQL_INSERTAR)
                .param("cid", e.conversacionId())
                .param("fkUsuario", e.fkUsuario())
                .param("capa", e.capa())
                .param("riesgo", e.riesgo())
                .param("motivo", e.motivo())
                .param("hash", e.fragmentoHash())
                .param("actor", Auditoria.ACTOR)
                .query(Long.class)
                .single();
    }
}
