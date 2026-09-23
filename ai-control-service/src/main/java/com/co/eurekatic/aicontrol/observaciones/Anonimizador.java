package com.co.eurekatic.aicontrol.observaciones;

import java.text.Normalizer;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Saca el nombre del estudiante de lo que viaja al proveedor y lo vuelve a
 * poner en la respuesta.
 *
 * <p>Las observaciones son de menores de edad y el proveedor es externo, asi
 * que al modelo no se le manda ningun identificador: se le pide que escriba
 * {@link #MARCADOR} donde iria el nombre. Si el docente escribio el nombre
 * dentro de una observacion, tambien se reemplaza antes de enviarla. Es una
 * defensa de mejor esfuerzo: solo se conoce el primer nombre.
 *
 * <p>El marcador usa corchetes y no llaves porque las plantillas de Spring AI
 * (StringTemplate) interpretan las llaves como variables.
 */
public final class Anonimizador {

    public static final String MARCADOR = "[ESTUDIANTE]";
    private static final String GENERICO = "el estudiante";

    private Anonimizador() {}

    public static String ocultar(String texto, String nombre) {
        if (texto == null || nombre == null || nombre.isBlank()) {
            return texto;
        }
        Pattern p = Pattern.compile("(?iu)(?<![\\p{L}])" + Pattern.quote(nombre.trim()) + "(?![\\p{L}])");
        String resultado = p.matcher(texto).replaceAll(Matcher.quoteReplacement(MARCADOR));
        // El docente pudo escribir el nombre sin tilde (o con ella) al reves
        // que el registro.
        String sinTildes = quitarTildes(nombre.trim());
        if (!sinTildes.equalsIgnoreCase(nombre.trim())) {
            Pattern p2 = Pattern.compile("(?iu)(?<![\\p{L}])" + Pattern.quote(sinTildes) + "(?![\\p{L}])");
            resultado = p2.matcher(resultado).replaceAll(Matcher.quoteReplacement(MARCADOR));
        }
        return resultado;
    }

    /**
     * Reinserta el nombre. Sin nombre cae a "el estudiante", con mayuscula
     * cuando abre oracion.
     */
    public static String restaurar(String texto, String nombre) {
        if (texto == null) {
            return null;
        }
        boolean hayNombre = nombre != null && !nombre.isBlank();
        String reemplazo = hayNombre ? capitalizar(nombre.trim().toLowerCase()) : GENERICO;
        StringBuilder out = new StringBuilder(texto.length() + 32);
        int desde = 0;
        int i;
        while ((i = texto.indexOf(MARCADOR, desde)) >= 0) {
            out.append(texto, desde, i);
            out.append(!hayNombre && abreOracion(out) ? capitalizar(reemplazo) : reemplazo);
            desde = i + MARCADOR.length();
        }
        out.append(texto.substring(desde));
        return out.toString();
    }

    private static boolean abreOracion(CharSequence previo) {
        for (int k = previo.length() - 1; k >= 0; k--) {
            char c = previo.charAt(k);
            if (Character.isWhitespace(c)) continue;
            return c == '.' || c == '!' || c == '?' || c == ':' || c == '\n';
        }
        return true;
    }

    private static String capitalizar(String s) {
        return s.isEmpty() ? s : Character.toUpperCase(s.charAt(0)) + s.substring(1);
    }

    private static String quitarTildes(String s) {
        return Normalizer.normalize(s, Normalizer.Form.NFD).replaceAll("\\p{M}", "");
    }
}
