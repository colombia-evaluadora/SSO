package com.co.eurekatic.aicontrol.agente.persistencia;

/** Resultado de una consulta analitica, como lo guarda {@code ai.consulta_analitica.estado}. */
public enum EstadoConsulta {
    OK,
    RECHAZADA,
    ERROR,
    TIMEOUT
}
