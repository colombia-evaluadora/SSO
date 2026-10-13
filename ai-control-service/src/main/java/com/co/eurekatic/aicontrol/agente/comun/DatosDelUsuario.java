package com.co.eurekatic.aicontrol.agente.comun;

import java.util.regex.Pattern;

/**
 * Encierra un texto que no es instruccion (mensaje del usuario, resultado de una herramienta,
 * contexto de pantalla) en una etiqueta. Si el texto trae la etiqueta de cierre, se neutraliza para
 * que no pueda cerrar el bloque de datos. Pura.
 */
public final class DatosDelUsuario {

    private static final String SUSTITUTO = "[etiqueta]";

    private DatosDelUsuario() {
    }

    public static String bloque(String etiqueta, String contenido) {
        Pattern cierre = Pattern.compile("(?i)</?\\s*" + Pattern.quote(etiqueta) + "\\s*>");
        String seguro = cierre.matcher(contenido).replaceAll(SUSTITUTO);
        return "<" + etiqueta + ">\n" + seguro + "\n</" + etiqueta + ">";
    }
}
