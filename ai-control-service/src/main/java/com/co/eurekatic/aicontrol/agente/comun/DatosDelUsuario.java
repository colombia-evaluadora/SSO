package com.co.eurekatic.aicontrol.agente.comun;

import java.util.regex.Pattern;

/**
 * Encierra un texto que no es instruccion (mensaje del usuario, resultado de una herramienta,
 * contexto de pantalla) en una etiqueta. Si el texto trae la etiqueta de cierre, se neutraliza para
 * que no pueda cerrar el bloque de datos. Pura.
 */
public final class DatosDelUsuario {

    private static final String SUSTITUTO = "[etiqueta]";
    private static final String ETIQUETA_MENSAJE = "mensaje_usuario";

    private DatosDelUsuario() {
    }

    /**
     * El mensaje de la persona tal como lo ve el modelo, en el turno y al reconstruir la memoria: siempre
     * dentro de su bloque, para que el modelo lo trate como dato y no como instruccion.
     */
    public static String mensaje(String textoNormalizado) {
        return bloque(ETIQUETA_MENSAJE, textoNormalizado);
    }

    public static String bloque(String etiqueta, String contenido) {
        Pattern cierre = Pattern.compile("(?i)</?\\s*" + Pattern.quote(etiqueta) + "\\s*>");
        String seguro = cierre.matcher(contenido).replaceAll(SUSTITUTO);
        return "<" + etiqueta + ">\n" + seguro + "\n</" + etiqueta + ">";
    }
}
