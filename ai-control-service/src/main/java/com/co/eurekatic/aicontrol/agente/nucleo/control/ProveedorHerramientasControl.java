package com.co.eurekatic.aicontrol.agente.nucleo.control;

import org.springframework.ai.tool.ToolCallback;

import java.util.List;

/**
 * Punto de extension de las herramientas de control: cada bean que lo implementa aporta sus callbacks
 * y el turno los recolecta. Se ofrecen cuando la intencion admite herramientas de control. Sus nombres
 * no pueden coincidir con codigos del catalogo.
 *
 * <p>Los callbacks no guardan estado de turno: lo leen del {@code ToolContext} con
 * {@link com.co.eurekatic.aicontrol.agente.nucleo.TurnoContexto#de}.
 */
public interface ProveedorHerramientasControl {

    List<ToolCallback> callbacks();

    /** Si actua sobre la pantalla de la persona: con riesgo MEDIO esas herramientas no se ofrecen. */
    default boolean manejaPantalla() {
        return false;
    }
}
