package com.co.eurekatic.aicontrol.agente.seguridad;

/**
 * Filtro que originó un evento de seguridad. Coincide con el valor de
 * {@code ai.evento_seguridad.capa}.
 */
public enum CapaSeguridad {
    FIREWALL,
    CLASIFICADOR,
    ARGUMENTOS,
    SQL,
    UI,
    SALIDA
}
