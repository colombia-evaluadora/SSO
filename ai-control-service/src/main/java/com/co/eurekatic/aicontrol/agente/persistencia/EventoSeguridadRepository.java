package com.co.eurekatic.aicontrol.agente.persistencia;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

import java.util.UUID;

/**
 * Bloqueos y descartes del agente, en {@code ai.evento_seguridad}. Guarda la
 * huella del fragmento sospechoso, nunca el texto.
 */
@Repository
public class EventoSeguridadRepository {

    private final JdbcClient jdbc;

    public EventoSeguridadRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    /**
     * Datos de un evento. {@code capa} identifica el filtro que actuo;
     * {@code riesgo} es BAJO, MEDIO o ALTO; {@code conversacionId} puede ser null.
     */
    public record NuevoEvento(UUID conversacionId, long fkUsuario, String capa, String riesgo,
                              String motivo, String fragmentoHash) {
    }

    /** @return id del evento insertado */
    public long insertar(NuevoEvento e) {
        return jdbc.sql("""
                        INSERT INTO ai.evento_seguridad (conversacion_id, fk_usuario, capa, riesgo, motivo,
                                                         fragmento_hash, created_by)
                        VALUES (:cid, :fkUsuario, :capa, :riesgo, :motivo, :hash, :actor)
                        RETURNING id
                        """)
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
