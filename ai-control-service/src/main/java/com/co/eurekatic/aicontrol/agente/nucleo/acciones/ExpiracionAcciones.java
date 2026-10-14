package com.co.eurekatic.aicontrol.agente.nucleo.acciones;

import com.co.eurekatic.aicontrol.agente.persistencia.accion.AccionPendienteStore;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * Marca como EXPIRADA las acciones que nadie confirmo a tiempo. La confirmacion ya rechaza las
 * vencidas; esta tarea solo limpia el estado para el historial.
 */
@Component
public class ExpiracionAcciones {

    private static final Logger log = LoggerFactory.getLogger(ExpiracionAcciones.class);
    private static final long PERIODO_MS = 60_000L;

    private final AccionPendienteStore acciones;

    public ExpiracionAcciones(AccionPendienteStore acciones) {
        this.acciones = acciones;
    }

    @Scheduled(fixedDelay = PERIODO_MS, initialDelay = PERIODO_MS)
    public void marcarExpiradas() {
        int expiradas = acciones.marcarExpiradas();
        if (expiradas > 0) {
            log.info("Acciones pendientes expiradas: {}", expiradas);
        }
    }
}
