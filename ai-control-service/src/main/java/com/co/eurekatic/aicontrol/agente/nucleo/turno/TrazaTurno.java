package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/**
 * Recorrido de un turno por {@link EstadoTurno}. Valida cada paso con la maquina de estados y, al
 * cerrar, deja una linea de log con los estados (nunca el texto del turno).
 */
public final class TrazaTurno {

    private static final Logger log = LoggerFactory.getLogger(TrazaTurno.class);

    private final UUID conversacionId;
    private final List<EstadoTurno> pasos = new ArrayList<>();

    private TrazaTurno(UUID conversacionId) {
        this.conversacionId = Objects.requireNonNull(conversacionId, "conversacionId");
        this.pasos.add(EstadoTurno.RECIBIDO);
    }

    public static TrazaTurno iniciar(UUID conversacionId) {
        return new TrazaTurno(conversacionId);
    }

    /**
     * @throws IllegalStateException si el paso no es una transicion permitida: es un error de programa
     */
    public void pasar(EstadoTurno nuevo) {
        EstadoTurno actual = estado();
        if (!actual.puedePasarA(nuevo)) {
            throw new IllegalStateException("Transicion de turno no permitida: " + actual + " -> " + nuevo);
        }
        pasos.add(nuevo);
    }

    public EstadoTurno estado() {
        return pasos.get(pasos.size() - 1);
    }

    /** Deja el recorrido en el log: estado final y pasos, sin contenido. */
    public void cerrar() {
        log.info("turno conversacion={} estado={} pasos={}", conversacionId, estado(), pasos);
    }
}
