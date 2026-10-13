package com.co.eurekatic.aicontrol.agente.nucleo;

import java.time.LocalDateTime;
import java.util.Objects;
import java.util.UUID;

/**
 * Accion de escritura preparada y pendiente de confirmacion: lo que el front necesita para mostrar
 * los botones.
 *
 * @param id      id de {@code ai.accion_pendiente}; es lo que se envia a confirmar o cancelar
 * @param resumen texto que ve el usuario para decidir
 * @param expira  hasta cuando puede confirmarse
 */
public record AccionPropuesta(UUID id, String resumen, LocalDateTime expira) {

    public AccionPropuesta {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(resumen, "resumen");
        Objects.requireNonNull(expira, "expira");
    }
}
