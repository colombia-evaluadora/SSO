package com.co.eurekatic.aicontrol.agente.memoria;

/**
 * Como vuelve al modelo una respuesta anterior. Las confirmaciones y las acciones de UI las produjo el sistema
 * (una herramienta), no el modelo; si vuelven como texto literal, el modelo las imita en el turno siguiente y
 * "confirma" o "rellena" sin llamar a nada. Por eso vuelven como un recuerdo en pasado de lo que hizo la
 * herramienta. El modelo puede imitar tambien este formato: lo que lo frena es la guarda de afirmaciones del
 * turno, que reconoce estas frases. Pura.
 */
public final class NotaDeMemoria {

    /** Comienzo del texto de toda confirmacion real; lo usa el turno al proponer y aqui para resumirla. */
    public static final String PREFIJO_CONFIRMACION = "Antes de hacerlo necesito tu confirmación: ";

    private NotaDeMemoria() {
    }

    /**
     * @param tipoRespuesta tipo con que se mostro (RESPUESTA, CONFIRMACION, UI...); null en mensajes antiguos
     */
    public static String para(String tipoRespuesta, String texto) {
        if (tipoRespuesta == null) {
            return texto;
        }
        return switch (tipoRespuesta) {
            case "CONFIRMACION" -> "Prepare con la herramienta la accion «" + sinPrefijo(texto)
                    + "», que espera el boton Confirmar de la persona; todavia no se ha ejecutado.";
            case "UI" -> "Envie acciones a la pantalla con la herramienta y le dije a la persona: " + texto;
            default -> texto;
        };
    }

    private static String sinPrefijo(String texto) {
        return texto.startsWith(PREFIJO_CONFIRMACION) ? texto.substring(PREFIJO_CONFIRMACION.length()) : texto;
    }
}
