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
    static final String SIN_HERRAMIENTA = "No he podido completar esa petición. Prueba a pedirlo en pasos más concretos.";

    /** El modelo escribio la llamada como texto (XML o marcas del proveedor) en vez de hacerla: nada se ejecuto. */
    private static final Pattern LLAMADA_EN_TEXTO = Pattern.compile(
            "<\\s*/?\\s*(tool_call|tool|function_call|function|invoke|parameter)\\b|\\[/?tool_call\\]"
                    // Tambien como JSON: {"name": "estructura_esperada", "input"|"arguments"|"parameters": {...}}
                    + "|\\{\\s*\"(name|tool|function)\"\\s*:\\s*\"[a-z_]+\"\\s*,\\s*\"(input|arguments|parameters|args)\"\\s*:");

    /** Si el texto trae una llamada a herramienta escrita en vez de hecha. */
    static boolean esLlamadaEnTexto(String texto) {
        return texto != null && LLAMADA_EN_TEXTO.matcher(texto).find();
    }

    private static final Pattern CONFIRMACION = Pattern.compile(
            "necesito tu confirmacion|(espera|pendiente de|requiere) (de )?tu confirmacion|pulsa confirmar|boton confirmar"
                    + "|prepare con la herramienta");
    /**
     * Un cambio en la base contado como hecho ("se actualizo la fecha"). Tambien lo dice un dato historico ("se
     * creo el 1 de octubre"), asi que solo se objeta: si el modelo lo mantiene tras revisarlo, queda.
     */
    private static final Pattern CAMBIO_IMPERSONAL = Pattern.compile(
            "\\bse (actualizo|cambio|modifico|creo|guardo|registro|asigno|califico|elimino|vinculo)\\b"
                    + "|\\b(quedo|ha quedado|quedaron|han quedado) (actualizad|cambiad|registrad|guardad|asignad|calificad|cread)");
    static final String CAMBIO_SIN_ESCRITURA = "Control del sistema: tu respuesta cuenta un cambio en la base como "
            + "hecho, pero en este turno no se confirmo ninguna escritura. Si la persona pidio el cambio, llama a la "
            + "herramienta de escritura y el sistema le pedira confirmar; si es un dato leido, dilo como tal.";
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

    /**
     * Lo que se le devuelve al modelo para que rehaga un texto que afirma lo que no hizo, o que ofrece consultar
     * en vez de hacerlo ("si quiere, puedo consultarla"). Lo segundo no se sustituye si insiste: es honesto.
     */
    static Optional<String> objecion(RespuestaAgente respuesta) {
        Optional<String> afirmada = afirmacion(respuesta).map(a -> a.objecion);
        if (afirmada.isPresent() || !(respuesta instanceof RespuestaAgente.Respuesta texto)) {
            return afirmada;
        }
        String plegado = NormalizadorTexto.plegar(texto.texto());
        if (CAMBIO_IMPERSONAL.matcher(plegado).find()) {
            return Optional.of(CAMBIO_SIN_ESCRITURA);
        }
        return OFRECE_CONSULTAR.matcher(plegado).find()
                ? Optional.of(CONSULTA_EN_VEZ_DE_OFRECER)
                : Optional.empty();
    }

    /** "Si quiere, puedo consultarla", "revisela en su pantalla": ofrecer o mandar a buscar lo que una consulta da. */
    private static final Pattern OFRECE_CONSULTAR = Pattern.compile(
            "\\b(si (quieres|quiere|deseas|desea)|quieres que|desea que|puedo)\\b.{0,40}\\b(consult|busc|revis|averigu)\\w*"
                    + "|\\brevis\\w* en (tu|su) pantalla");
    static final String CONSULTA_EN_VEZ_DE_OFRECER = "Control del sistema: ofreces consultar o mandas a la persona a "
            + "buscar, pero lo que pidio sale de una consulta que tienes disponible. Haz la consulta ahora y respondele "
            + "con el dato.";

    private static Optional<Afirmacion> afirmacion(RespuestaAgente respuesta) {
        if (!(respuesta instanceof RespuestaAgente.Respuesta texto)) {
            return Optional.empty();
        }
        if (LLAMADA_EN_TEXTO.matcher(texto.texto()).find()) {
            return Optional.of(Afirmacion.LLAMADA);
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
                + "no se puede, explicalo sin decir que lo hiciste."),
        LLAMADA(SIN_HERRAMIENTA, "Control del sistema: escribiste una llamada a herramienta como texto y no se "
                + "ejecuto nada. Llama a la herramienta por la interfaz de herramientas, solo con las que se te ofrecen "
                + "en este turno; nunca escribas XML ni etiquetas de herramienta en la respuesta.");

        private final String sustituto;
        private final String objecion;

        Afirmacion(String sustituto, String objecion) {
            this.sustituto = sustituto;
            this.objecion = objecion;
        }
    }
}
