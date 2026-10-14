package com.co.eurekatic.aicontrol.agente.persistencia.herramienta;

import java.util.List;
import java.util.Objects;
import java.util.UUID;

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

    /**
     * Una invocacion ya guardada: lo que el historial del modelo recuerda de ella.
     *
     * @param argumentosJson las claves que mando el modelo, nunca sus valores
     */
    record Invocacion(long id, long mensajeId, String nombre, String argumentosJson, String resultadoResumen) {
    }

    /** Invocaciones de la conversacion, en el orden en que se hicieron. */
    List<Invocacion> listarPorConversacion(UUID conversacionId);
}
