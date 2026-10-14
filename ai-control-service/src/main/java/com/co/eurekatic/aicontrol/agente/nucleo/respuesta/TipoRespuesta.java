package com.co.eurekatic.aicontrol.agente.nucleo.respuesta;

/**
 * Tipo de respuesta del agente. El nombre es el valor que se guarda en {@code ai.mensaje.tipo_respuesta}
 * y el que ve el front en el campo {@code tipo}.
 */
public enum TipoRespuesta {
    RESPUESTA,
    PREGUNTA,
    CONFIRMACION,
    UI,
    DATOS,
    BLOQUEADO,
    SIN_PERMISO
}
