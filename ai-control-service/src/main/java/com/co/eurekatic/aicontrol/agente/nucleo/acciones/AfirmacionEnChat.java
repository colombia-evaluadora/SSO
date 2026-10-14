package com.co.eurekatic.aicontrol.agente.nucleo.acciones;

import com.co.eurekatic.aicontrol.agente.seguridad.NormalizadorTexto;

import java.util.Set;

/**
 * Reconoce un "si" escrito en el chat ("si, confirmo", "dale", "hazlo"). Con una accion pendiente, ese mensaje
 * no va al modelo: una confirmacion escrita no ejecuta nada, y si el modelo la recibe tiende a contestar
 * "procedo" como si la hubiera hecho. Pura.
 */
public final class AfirmacionEnChat {

    private static final int LONGITUD_MAXIMA = 40;
    private static final Set<String> AFIRMACIONES = Set.of(
            "si", "si confirmo", "confirmo", "confirmar", "confirmado", "ok", "okay", "dale", "hazlo", "adelante",
            "de acuerdo", "correcto", "procede", "ejecuta", "ejecutalo", "si hazlo", "si dale", "si adelante",
            "si por favor", "claro", "claro que si", "vale", "listo");

    private AfirmacionEnChat() {
    }

    public static boolean es(String texto) {
        if (texto == null || texto.length() > LONGITUD_MAXIMA) {
            return false;
        }
        String limpio = NormalizadorTexto.plegar(texto).replaceAll("[^\\p{L}\\p{N} ]", " ").strip().replaceAll("\\s+", " ");
        return AFIRMACIONES.contains(limpio);
    }
}
