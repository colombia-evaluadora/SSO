package com.co.eurekatic.aicontrol.agente.seguridad;

import java.util.List;

/**
 * Texto final del agente tras la revision de salida.
 *
 * @param texto      lo que se devuelve al usuario
 * @param redactado  true si se cambio algo (bloqueo completo o redaccion)
 * @param motivos    codigos de motivo, sin duplicados y en orden de deteccion
 */
public record ResultadoSalida(String texto, boolean redactado, List<String> motivos) {

    /** Fuga del prompt: ALTO. Tokens o PII: MEDIO. Sin hallazgos: BAJO. */
    public Riesgo riesgo() {
        if (motivos.contains(SalidaSegura.MOTIVO_PROMPT)) {
            return Riesgo.ALTO;
        }
        return motivos.isEmpty() ? Riesgo.BAJO : Riesgo.MEDIO;
    }
}
