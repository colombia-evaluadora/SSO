package com.co.eurekatic.aicontrol.agente.persistencia;

/** Resultado de una llamada a herramienta, como lo guarda {@code ai.tool_invocacion.estado}. */
public enum EstadoInvocacion {
    OK,
    ERROR,
    RECHAZADA,
    PENDIENTE,
    LIMITE
}
