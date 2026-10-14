package com.co.eurekatic.aicontrol.agente.memoria;

import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.InvocadorHerramientas;

/**
 * Como vuelve al modelo una respuesta anterior. Las confirmaciones, las preguntas, las acciones de UI y el
 * resultado de confirmar los produjo el sistema, no el modelo. Si vuelven como texto literal ("necesito tu
 * confirmacion") o como narracion en primera persona ("prepare con la herramienta..."), el modelo los imita y
 * "confirma" o cuenta consultas que no hizo. Por eso vuelven como un registro de estado entre corchetes, que el
 * prompt reserva al sistema y la guarda de afirmaciones reconoce si el modelo lo escribe. Pura.
 */
public final class NotaDeMemoria {

    /** Comienzo del texto de toda confirmacion real; lo usa el turno al proponer y aqui para resumirla. */
    public static final String PREFIJO_CONFIRMACION = "Antes de hacerlo necesito tu confirmación: ";

    /** Texto con que se muestra una pregunta de pedir_datos_faltantes; las preguntas van aparte. */
    public static final String TEXTO_PREGUNTA = "Para continuar necesito estos datos.";

    /** Comienzo del texto de una accion confirmada y ejecutada (lo escribe el servicio de acciones). */
    public static final String PREFIJO_HECHO = "Hecho: ";

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
            case "CONFIRMACION" -> "[Accion propuesta, pendiente de Confirmar: " + sinPrefijo(texto)
                    + ". Todavia no se ha ejecutado.]";
            case "UI" -> "[Cambios enviados a la pantalla. Texto mostrado: " + texto + "]";
            case "PREGUNTA" -> texto.startsWith(TEXTO_PREGUNTA)
                    ? "[Pregunta enviada a la persona; su respuesta llega en el mensaje siguiente.]"
                    : "[Pregunta enviada a la persona: " + texto + ". Su respuesta llega en el mensaje siguiente.]";
            default -> texto.startsWith(PREFIJO_HECHO)
                    ? "[Accion ejecutada tras confirmar: " + texto.substring(PREFIJO_HECHO.length()) + "]"
                    : rechazoAlConfirmar(texto);
        };
    }

    /**
     * El rechazo del servicio al confirmar ("Datos no validos ...: indique el peso") vuelve con lo que hay que hacer:
     * si no, el modelo recibe el dato que faltaba y no rehace la accion.
     */
    private static String rechazoAlConfirmar(String texto) {
        boolean rechazo = InvocadorHerramientas.PREFIJOS_RECHAZO.stream().anyMatch(texto::startsWith);
        return rechazo
                ? "[Accion rechazada por el servicio al confirmar: " + texto + " Cuando la persona de el dato que "
                        + "falta, vuelve a llamar a la misma herramienta de escritura con todos los datos de esa accion "
                        + "mas el nuevo.]"
                : texto;
    }

    private static String sinPrefijo(String texto) {
        String resumen = texto.startsWith(PREFIJO_CONFIRMACION) ? texto.substring(PREFIJO_CONFIRMACION.length()) : texto;
        return resumen.endsWith(".") ? resumen.substring(0, resumen.length() - 1) : resumen;
    }
}
