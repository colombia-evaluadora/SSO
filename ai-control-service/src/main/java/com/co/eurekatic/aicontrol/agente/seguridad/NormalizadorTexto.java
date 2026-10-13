package com.co.eurekatic.aicontrol.agente.seguridad;

import java.text.Normalizer;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * Normalizacion de texto para los filtros, en la entrada y en la salida. Pura:
 * sin estado ni Spring.
 */
public final class NormalizadorTexto {

    private static final Pattern MARCAS = Pattern.compile("\\p{M}+");
    private static final Pattern ESPACIOS = Pattern.compile("\\s+");

    private NormalizadorTexto() {
    }

    /**
     * NFKC, y fuera los caracteres de control (salvo salto de linea y tabulador)
     * y de formato: ancho cero, marcas bidi, BOM, soft hyphen. Es el texto que se
     * audita por huella.
     */
    public static String normalizar(String texto) {
        String nfkc = Normalizer.normalize(texto, Normalizer.Form.NFKC);
        StringBuilder sb = new StringBuilder(nfkc.length());
        nfkc.codePoints().filter(NormalizadorTexto::conservable).forEach(sb::appendCodePoint);
        return sb.toString().strip();
    }

    /** Minusculas, sin marcas diacriticas y con espacios colapsados: para comparar frases. */
    public static String plegar(String texto) {
        String sinTildes = MARCAS.matcher(
                Normalizer.normalize(texto.toLowerCase(Locale.ROOT), Normalizer.Form.NFD)).replaceAll("");
        return ESPACIOS.matcher(sinTildes).replaceAll(" ");
    }

    private static boolean conservable(int cp) {
        if (cp == '\n' || cp == '\t') {
            return true;
        }
        int tipo = Character.getType(cp);
        return tipo != Character.CONTROL && tipo != Character.FORMAT;
    }
}
