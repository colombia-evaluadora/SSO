package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;

import java.util.function.Supplier;

/**
 * Cancelacion de un turno en curso. El bucle la comprueba entre vueltas; durante una llamada al modelo,
 * cancelar interrumpe el hilo para no esperar la respuesta del proveedor.
 *
 * <p>La interrupcion solo se lanza mientras el hilo esta dentro de {@link #interrumpible}, y al salir se
 * limpia la marca: un hilo del pool no puede quedar interrumpido para la siguiente peticion.
 */
public final class SenalCancelacion {

    private volatile boolean cancelada;
    private Thread enLlamada;

    /** Marca el turno como cancelado e interrumpe la llamada al modelo si hay una en marcha. */
    public synchronized void cancelar() {
        cancelada = true;
        if (enLlamada != null) {
            enLlamada.interrupt();
        }
    }

    public boolean cancelada() {
        return cancelada;
    }

    /** @throws ErrorAgente.TurnoCancelado si el turno se cancelo */
    public void comprobar() {
        if (cancelada) {
            throw new ErrorAgente.TurnoCancelado();
        }
    }

    /**
     * Ejecuta una llamada que se puede cortar con {@link #cancelar()}. Si se cancela durante la llamada, el
     * fallo que provoque la interrupcion se traduce a {@link ErrorAgente.TurnoCancelado}.
     */
    public <T> T interrumpible(Supplier<T> llamada) {
        comprobar();
        synchronized (this) {
            enLlamada = Thread.currentThread();
        }
        T resultado;
        try {
            resultado = llamada.get();
        } catch (RuntimeException e) {
            if (cancelada) {
                throw new ErrorAgente.TurnoCancelado();
            }
            throw e;
        } finally {
            synchronized (this) {
                enLlamada = null;
            }
            // Fuera del bloque ya nadie interrumpe: se limpia una marca que haya llegado tarde.
            Thread.interrupted();
        }
        comprobar();
        return resultado;
    }
}
