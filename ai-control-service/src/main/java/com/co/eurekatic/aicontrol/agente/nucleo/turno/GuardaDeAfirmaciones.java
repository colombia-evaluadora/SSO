package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.seguridad.NormalizadorTexto;

import java.util.Optional;
import java.util.regex.Pattern;

/**
 * Un texto final del modelo nunca puede afirmar algo que solo una herramienta hace. En el turno el modelo no
 * ejecuta escrituras ni toca la pantalla: si escribe una confirmacion ("necesito tu confirmacion") sin haber
 * propuesto nada, o dice "listo, rellene..." sin acciones de UI, esta imitando el historial. Ese texto se
 * devuelve al modelo una vez con una objecion ({@link #objecion}) y, si insiste, se sustituye por uno honesto.
 * Pura; solo mira respuestas de texto simple.
 */
final class GuardaDeAfirmaciones {

    static final String SIN_ACCION = "No llegué a preparar esa acción. Pídemela de nuevo con los datos y te "
            + "mostraré el botón para confirmarla.";
    static final String SIN_PANTALLA = "No llegué a aplicar ese cambio en tu pantalla. Pídemelo de nuevo.";

    private static final Pattern CONFIRMACION = Pattern.compile(
            "necesito tu confirmacion|(espera|pendiente de|requiere) (de )?tu confirmacion|pulsa confirmar|boton confirmar"
                    + "|prepare con la herramienta");
    private static final Pattern CAMBIO_HECHO = Pattern.compile(
            "^\\W*(listo|hecho|ya)\\b.{0,80}?\\b(rellene|resalte|llene|actualice|marque|escribi|cambie|te lleve|edite)\\b"
                    + "|\\bhice (fue )?(rellenar|resaltar|llenar|actualizar|marcar|escribir|cambiar|poner)\\b"
                    + "|\\b(he|hemos) (rellenado|resaltado|llenado|actualizado|marcado|escrito|cambiado|puesto)\\b"
                    + "|\\bya (rellene|resalte|llene|actualice|marque|escribi|cambie|puse)\\b"
                    + "|envie acciones a la pantalla|^\\W*\\[sistema");

    private GuardaDeAfirmaciones() {
    }

    static RespuestaAgente revisar(RespuestaAgente respuesta) {
        return afirmacion(respuesta).map(a -> (RespuestaAgente) new RespuestaAgente.Respuesta(a.sustituto))
                .orElse(respuesta);
    }

    /** Lo que se le devuelve al modelo para que rehaga un texto que afirma lo que no hizo. */
    static Optional<String> objecion(RespuestaAgente respuesta) {
        return afirmacion(respuesta).map(a -> a.objecion);
    }

    private static Optional<Afirmacion> afirmacion(RespuestaAgente respuesta) {
        if (!(respuesta instanceof RespuestaAgente.Respuesta texto)) {
            return Optional.empty();
        }
        String plegado = NormalizadorTexto.plegar(texto.texto());
        if (CONFIRMACION.matcher(plegado).find()) {
            return Optional.of(Afirmacion.ACCION);
        }
        return CAMBIO_HECHO.matcher(plegado).find() ? Optional.of(Afirmacion.PANTALLA) : Optional.empty();
    }

    private enum Afirmacion {
        ACCION(SIN_ACCION, "Control del sistema: tu respuesta dice que preparaste una accion, pero en este turno no "
                + "llamaste a ninguna herramienta de escritura, asi que no hay nada que confirmar. Si la persona la "
                + "pidio, llama ahora a la herramienta con los datos; si te falta alguno, pidelo. No repitas el "
                + "historial."),
        PANTALLA(SIN_PANTALLA, "Control del sistema: tu respuesta dice que cambiaste la pantalla, pero en este turno "
                + "no llamaste a accion_ui, asi que nada cambio. Si la persona lo pidio, llama ahora a accion_ui; si "
                + "no se puede, explicalo sin decir que lo hiciste.");

        private final String sustituto;
        private final String objecion;

        Afirmacion(String sustituto, String objecion) {
            this.sustituto = sustituto;
            this.objecion = objecion;
        }
    }
}
