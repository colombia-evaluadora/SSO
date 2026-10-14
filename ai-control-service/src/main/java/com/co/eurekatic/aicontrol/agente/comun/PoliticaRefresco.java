package com.co.eurekatic.aicontrol.agente.comun;

import java.time.Duration;
import java.time.Instant;

/**
 * Cuando recargar un catalogo en memoria leido de la base: siempre si esta vacio (arranque o base caida),
 * y si no, cuando vence el intervalo.
 */
public final class PoliticaRefresco {

    private PoliticaRefresco() {
    }

    public static boolean toca(boolean vacio, Instant ultimaCarga, Instant ahora, Duration intervalo) {
        return vacio || !ahora.isBefore(ultimaCarga.plus(intervalo));
    }
}
