package com.co.eurekatic.aicontrol.agente.nucleo.respuesta;

/**
 * Accion de UI que el agente devuelve al front (seccion 8 de la propuesta). Este componente no define
 * ninguna: la fase de UI sustituye el marcador por sus records (Navegar, Rellenar, ...) y los anade a
 * {@code permits}. Mientras tanto una {@link RespuestaAgente.Ui} no puede llevar acciones reales.
 */
public sealed interface AccionUi permits AccionUi.Pendiente {

    /** Marcador hasta que la fase de UI aporta sus acciones. */
    record Pendiente() implements AccionUi {
    }
}
