package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.nucleo.intencion.Intencion;
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
    private final ObservadorTurno observador;
    private final List<EstadoTurno> pasos = new ArrayList<>();
    private Intencion intencion;

    private TrazaTurno(UUID conversacionId, ObservadorTurno observador) {
        this.conversacionId = Objects.requireNonNull(conversacionId, "conversacionId");
        this.observador = Objects.requireNonNull(observador, "observador");
        this.pasos.add(EstadoTurno.RECIBIDO);
    }

    public static TrazaTurno iniciar(UUID conversacionId) {
        return new TrazaTurno(conversacionId, ObservadorTurno.NINGUNO);
    }

    /** Traza que ademas avisa de cada paso, p. ej. al streaming. */
    public static TrazaTurno iniciar(UUID conversacionId, ObservadorTurno observador) {
        return new TrazaTurno(conversacionId, observador);
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
        avisar(nuevo);
    }

    private void avisar(EstadoTurno nuevo) {
        try {
            observador.alPasar(nuevo);
        } catch (RuntimeException e) {
            log.warn("El observador del turno fallo: {}", e.getClass().getSimpleName());
        }
    }

    public EstadoTurno estado() {
        return pasos.get(pasos.size() - 1);
    }

    /** Intencion clasificada: decide que herramientas vio el modelo, asi que sale en el log del turno. */
    public void anotar(Intencion clasificada) {
        this.intencion = clasificada;
    }

    /** Deja el recorrido en el log: estado final, pasos e intencion (tipo y riesgo), sin contenido. */
    public void cerrar() {
        log.info("turno conversacion={} estado={} pasos={} intencion={} riesgo={}", conversacionId, estado(), pasos,
                intencion == null ? "-" : intencion.tipo(), intencion == null ? "-" : intencion.riesgo());
    }
}
