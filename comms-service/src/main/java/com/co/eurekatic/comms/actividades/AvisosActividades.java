package com.co.eurekatic.comms.actividades;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Avisos programados: comunicados cuya hora de publicacion llego y
 * encuestas/elecciones/evaluaciones que abren en una fecha futura. Cada
 * aviso se reclama con {@code UPDATE ... SET notificado_en WHERE notificado_en
 * IS NULL RETURNING}, asi varias replicas no lo duplican.
 */
@Component
public class AvisosActividades {

    private static final Logger log = LoggerFactory.getLogger(AvisosActividades.class);

    private final ComunicadoService comunicados;
    private final EncuestaService encuestas;
    private final EleccionService elecciones;
    private final EvaluacionService evaluaciones;

    public AvisosActividades(ComunicadoService comunicados, EncuestaService encuestas, EleccionService elecciones,
                             EvaluacionService evaluaciones) {
        this.comunicados = comunicados;
        this.encuestas = encuestas;
        this.elecciones = elecciones;
        this.evaluaciones = evaluaciones;
    }

    @Scheduled(fixedDelayString = "${comms.actividades.avisos-ms:30000}", initialDelay = 10_000)
    public void revisar() {
        Runnable[] tareas = {comunicados::avisarPublicados, encuestas::avisarAbiertas, elecciones::avisarAbiertas,
                evaluaciones::avisarAbiertas};
        for (Runnable t : tareas) {
            try {
                t.run();
            } catch (RuntimeException e) {
                log.warn("No se pudieron revisar los avisos de actividades: {}", e.getMessage());
            }
        }
    }
}
