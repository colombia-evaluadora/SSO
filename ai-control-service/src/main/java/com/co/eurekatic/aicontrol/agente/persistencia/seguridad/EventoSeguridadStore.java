package com.co.eurekatic.aicontrol.agente.persistencia.seguridad;

import java.util.UUID;

/** Bloqueos y descartes del agente. Guarda la huella del texto, nunca el texto. */
public interface EventoSeguridadStore {

    /**
     * Datos de un evento. {@code capa}, {@code riesgo} y {@code motivo} son los
     * nombres que guarda la tabla; {@code conversacionId} y {@code fragmentoHash} pueden ser null.
     */
    record NuevoEvento(UUID conversacionId, long fkUsuario, String capa, String riesgo,
                       String motivo, String fragmentoHash) {
    }

    /** @return id del evento insertado */
    long insertar(NuevoEvento evento);
}
