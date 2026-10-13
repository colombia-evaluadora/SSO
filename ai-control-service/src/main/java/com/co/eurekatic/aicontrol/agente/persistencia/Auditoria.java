package com.co.eurekatic.aicontrol.agente.persistencia;

/**
 * Valor de {@code created_by} y {@code modified_by} para todo lo que escribe
 * el agente. Quien es dueño de cada fila va en {@code fk_usuario}; esta
 * columna solo dice que fue el servicio, asi que es la misma en todas las
 * tablas.
 */
public final class Auditoria {

    public static final String ACTOR = "ai-control-service";

    private Auditoria() {
    }
}
