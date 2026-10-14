package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.seguridad.NormalizadorTexto;

import java.util.regex.Pattern;

/**
 * Un texto final del modelo nunca puede afirmar algo que solo una herramienta hace. En el turno el modelo no
 * ejecuta escrituras ni toca la pantalla: si escribe una confirmacion ("necesito tu confirmacion") sin haber
 * propuesto nada, o dice "listo, rellene..." sin acciones de UI, esta imitando el historial. Ese texto se
 * sustituye por uno honesto. Pura; solo mira respuestas de texto simple.
 */
final class GuardaDeAfirmaciones {

    static final String SIN_ACCION = "No llegué a preparar esa acción. Pídemela de nuevo con los datos y te "
            + "mostraré el botón para confirmarla.";
    static final String SIN_PANTALLA = "No llegué a aplicar ese cambio en tu pantalla. Pídemelo de nuevo.";

    private static final Pattern CONFIRMACION = Pattern.compile(
            "necesito tu confirmacion|pulsa confirmar|boton confirmar|prepare con la herramienta");
    private static final Pattern CAMBIO_HECHO = Pattern.compile(
            "^\\W*(listo|hecho|ya)\\b.{0,80}?\\b(rellene|resalte|llene|actualice|marque|escribi|cambie|te lleve|edite)\\b"
                    + "|\\bhice (fue )?(rellenar|resaltar|llenar|actualizar|marcar|escribir|cambiar|poner)\\b"
                    + "|\\b(he|hemos) (rellenado|resaltado|llenado|actualizado|marcado|escrito|cambiado|puesto)\\b"
                    + "|\\bya (rellene|resalte|llene|actualice|marque|escribi|cambie|puse)\\b"
                    + "|envie acciones a la pantalla|^\\W*\\[sistema");

    private GuardaDeAfirmaciones() {
    }

    static RespuestaAgente revisar(RespuestaAgente respuesta) {
        if (!(respuesta instanceof RespuestaAgente.Respuesta texto)) {
            return respuesta;
        }
        String plegado = NormalizadorTexto.plegar(texto.texto());
        if (CONFIRMACION.matcher(plegado).find()) {
            return new RespuestaAgente.Respuesta(SIN_ACCION);
        }
        if (CAMBIO_HECHO.matcher(plegado).find()) {
            return new RespuestaAgente.Respuesta(SIN_PANTALLA);
        }
        return respuesta;
    }
}
