package com.co.eurekatic.aicontrol.agente.persistencia;

import java.util.Objects;

/** Registro de cada llamada a herramienta de un turno. */
public interface ToolInvocacionStore {

    /**
     * Datos de una invocacion. {@code argumentosJson} y {@code resultadoResumen}
     * llegan ya saneados por quien invoca: el almacen no filtra nada.
     */
    record NuevaInvocacion(long mensajeId, Long herramientaId, String nombre, String argumentosJson,
                           EstadoInvocacion estado, Integer httpStatus, String resultadoResumen,
                           Integer duracionMs) {

        public NuevaInvocacion {
            Objects.requireNonNull(nombre, "nombre");
            Objects.requireNonNull(estado, "estado");
        }
    }

    /** @return id de la invocacion insertada */
    long insertar(NuevaInvocacion invocacion);
}
