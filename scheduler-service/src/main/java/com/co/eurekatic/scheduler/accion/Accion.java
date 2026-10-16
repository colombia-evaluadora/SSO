package com.co.eurekatic.scheduler.accion;

/**
 * Punto de extension: un tipo de accion que una tarea puede ejecutar.
 * Para agregar uno basta con un {@code @Component} que implemente esta
 * interfaz; las tareas lo eligen por {@link #tipo()}.
 */
public interface Accion {

    /** Nombre con el que las tareas la referencian en {@code accion}. */
    String tipo();

    /**
     * Comprueba los parametros al arrancar, para que una tarea mal declarada
     * tumbe el arranque en vez de fallar en su primer disparo.
     */
    void validar(Parametros parametros);

    /** Ejecuta una vez. Cualquier excepcion cuenta como fallo del disparo. */
    void ejecutar(String tareaId, Parametros parametros) throws Exception;
}
