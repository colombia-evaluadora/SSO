package com.co.eurekatic.aicontrol.agente.web.dto;

import com.co.eurekatic.aicontrol.agente.nucleo.AccionPropuesta;

import java.time.LocalDateTime;
import java.util.UUID;

/**
 * Accion pendiente de confirmacion: el id va en las llamadas a confirmar o cancelar. {@code estado} es
 * PENDIENTE al proponerla; en el historial, su estado actual (EJECUTADA, FALLIDA, DESCARTADA, EXPIRADA).
 */
public record AccionPendienteDto(UUID id, String resumen, LocalDateTime expira, String estado) {

    public static AccionPendienteDto de(AccionPropuesta accion) {
        return new AccionPendienteDto(accion.id(), accion.resumen(), accion.expira(), "PENDIENTE");
    }
}
