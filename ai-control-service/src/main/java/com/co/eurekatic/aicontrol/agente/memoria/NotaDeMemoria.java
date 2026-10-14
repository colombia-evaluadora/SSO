package com.co.eurekatic.aicontrol.agente.memoria;

import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.InvocadorHerramientas;

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
            // Literal ("Para continuar necesito estos datos"), el modelo lo repite como respuesta sin preguntar nada.
            case "PREGUNTA" -> texto.startsWith(TEXTO_PREGUNTA)
                    ? "Pedi a la persona con la herramienta pedir_datos_faltantes los datos que faltaban; su respuesta "
                            + "llega en el mensaje siguiente."
                    : "Pedi a la persona con la herramienta pedir_datos_faltantes: " + texto + ". Su respuesta llega en "
                            + "el mensaje siguiente.";
            // El resultado de confirmar lo escribe el sistema: si vuelve literal ("Hecho: ..."), el modelo lo copia
            // y da por hecha una accion que no propuso.
            default -> texto.startsWith(PREFIJO_HECHO)
                    ? "La persona confirmo y el sistema ejecuto: " + texto.substring(PREFIJO_HECHO.length())
                    : rechazoAlConfirmar(texto);
        };
    }

    /** Texto con que se muestra una pregunta de pedir_datos_faltantes; las preguntas van aparte. */
    public static final String TEXTO_PREGUNTA = "Para continuar necesito estos datos.";

    /** Comienzo del texto de una accion confirmada y ejecutada (lo escribe el servicio de acciones). */
    public static final String PREFIJO_HECHO = "Hecho: ";

    /**
     * El rechazo del servicio al confirmar ("Datos no validos ...: indique el peso") vuelve con lo que hay que hacer:
     * si no, el modelo recibe el dato que faltaba y no rehace la accion.
     */
    private static String rechazoAlConfirmar(String texto) {
        boolean rechazo = InvocadorHerramientas.PREFIJOS_RECHAZO.stream().anyMatch(texto::startsWith);
        return rechazo
                ? "La persona confirmo la accion anterior pero el servicio la rechazo: " + texto + " Cuando la persona "
                        + "de el dato que falta, vuelve a llamar a la misma herramienta de escritura con todos los datos "
                        + "de esa accion mas el nuevo."
                : texto;
    }

    private static String sinPrefijo(String texto) {
        return texto.startsWith(PREFIJO_CONFIRMACION) ? texto.substring(PREFIJO_CONFIRMACION.length()) : texto;
    }
}
