package com.co.eurekatic.aicontrol.agente.web.dto;

import com.co.eurekatic.aicontrol.agente.nucleo.AccionPropuesta;

import java.time.LocalDateTime;
import java.util.UUID;

/** Accion pendiente de confirmacion: el id va en las llamadas a confirmar o cancelar. */
public record AccionPendienteDto(UUID id, String resumen, LocalDateTime expira) {

    public static AccionPendienteDto de(AccionPropuesta accion) {
        return new AccionPendienteDto(accion.id(), accion.resumen(), accion.expira());
    }
}
