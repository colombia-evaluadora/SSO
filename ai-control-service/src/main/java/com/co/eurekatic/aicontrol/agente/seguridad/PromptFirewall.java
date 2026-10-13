package com.co.eurekatic.aicontrol.agente.seguridad;

import com.co.eurekatic.aicontrol.config.AgenteProperties;
import org.springframework.stereotype.Component;

import java.text.Normalizer;
import java.util.List;
import java.util.Locale;
import java.util.regex.Pattern;

/**
 * Primera barrera de la entrada: determinista, sin modelo, antes de cualquier
 * llamada al proveedor.
 *
 * <p>Orden: NFKC, quitar caracteres de control y de formato (zero-width, bidi),
 * longitud maxima, y despues los patrones sobre el texto en minusculas y sin
 * tildes. Los patrones van sobre el texto plegado porque {@code SafeGuardAdvisor}
 * distingue mayusculas y se le escapan las variantes con tilde o ancho cero.
 *
 * <p>Los patrones tienen cuantificadores acotados: no hay anidados sin limite,
 * para que una entrada hostil no dispare backtracking.
 */
@Component
public class PromptFirewall {

    /** Patron con su riesgo y su codigo de motivo (baja cardinalidad: va a metricas). */
    record Patron(String motivo, Riesgo riesgo, Pattern regex) {
    }

    static final String MOTIVO_VACIO = "VACIO";
    static final String MOTIVO_LONGITUD = "LONGITUD";
    static final String MOTIVO_MEZCLA = "MEZCLA_ALFABETOS";

    /** Patrones sobre el texto plegado. El orden decide el motivo cuando hay empate de riesgo. */
    static final List<Patron> PATRONES = List.of(
            new Patron("INSTRUCCION_IGNORADA", Riesgo.ALTO, Pattern.compile(
                    "\\b(?:ignor|olvid|descart|desobedec)\\w*\\s+(?:\\S+\\s+){0,3}?(?:instrucciones|indicaciones|directrices|prompt)\\b"
                            + "|\\b(?:ignore|disregard|forget|override)\\s+(?:\\S+\\s+){0,3}?(?:instructions|prompt|directives)\\b")),
            new Patron("ROL_FORZADO", Riesgo.ALTO, Pattern.compile(
                    "(?<![\\p{L}\\d_])(?:system|assistant)\\s*:")),
            new Patron("MODO_SIN_LIMITES", Riesgo.ALTO, Pattern.compile(
                    "developer\\s+mode|modo\\s+(?:developer|desarrollador)|\\bjailbreak")),
            new Patron("REVELAR_PROMPT", Riesgo.ALTO, Pattern.compile(
                    "\\b(?:muestr|revel|dime|imprim|ensen|comparte)\\w*\\s+(?:\\S+\\s+){0,2}?"
                            + "(?:prompt|instrucciones\\s+(?:del\\s+sistema|internas|ocultas|originales)|mensaje\\s+de\\s+sistema)\\b"
                            + "|\\b(?:reveal|show|print|display|repeat|output|tell)\\w*\\s+(?:\\S+\\s+){0,2}?"
                            + "(?:system\\s+prompt|system\\s+message|initial\\s+prompt|hidden\\s+instructions|your\\s+prompt|your\\s+instructions)\\b")),
            new Patron("DELIMITADOR_FALSO", Riesgo.ALTO, Pattern.compile(
                    "<\\|[a-z_]*\\|>|\\[/?inst\\]|</?s>|</?system>|(?:```|~~~|###)\\s*system")),
            new Patron("IGNORAR_ANTERIOR", Riesgo.MEDIO, Pattern.compile(
                    "\\b(?:ignor|olvid)\\w*\\s+(?:todo\\s+)?lo\\s+(?:anterior|previo)\\b")),
            new Patron("ROL_CAMBIO", Riesgo.MEDIO, Pattern.compile(
                    "\\beres\\s+ahora\\b|\\byou\\s+are\\s+now\\b")),
            new Patron("HEX_LARGO", Riesgo.MEDIO, Pattern.compile("[0-9a-f]{200,}")),
            new Patron("BASE64_LARGO", Riesgo.MEDIO, Pattern.compile("[a-z0-9+/]{200,}={0,2}")));

    private final AgenteProperties props;

    public PromptFirewall(AgenteProperties props) {
        this.props = props;
    }

    /**
     * Revisa la entrada del usuario. Nunca lanza: una entrada nula es vacia.
     */
    public ResultadoFirewall revisar(String entrada) {
        String normalizado = normalizar(entrada == null ? "" : entrada);
        if (normalizado.isEmpty()) {
            return new ResultadoFirewall(false, "", Riesgo.BAJO, MOTIVO_VACIO);
        }
        if (normalizado.length() > props.textoMaxCaracteres()) {
            return new ResultadoFirewall(false, normalizado, Riesgo.ALTO, MOTIVO_LONGITUD);
        }

        String plegado = plegar(normalizado);
        Riesgo mayor = Riesgo.BAJO;
        String motivo = null;
        for (Patron p : PATRONES) {
            if (p.riesgo().compareTo(mayor) > 0 && p.regex().matcher(plegado).find()) {
                mayor = p.riesgo();
                motivo = p.motivo();
            }
        }
        if (Riesgo.MEDIO.compareTo(mayor) > 0 && mezclaAlfabetos(normalizado)) {
            mayor = Riesgo.MEDIO;
            motivo = MOTIVO_MEZCLA;
        }
        return new ResultadoFirewall(mayor != Riesgo.ALTO, normalizado, mayor, motivo);
    }

    /**
     * NFKC y fuera los caracteres de control (salvo salto de linea y tabulador)
     * y de formato: zero-width, marcas bidi, BOM, soft hyphen.
     */
    static String normalizar(String texto) {
        String nfkc = Normalizer.normalize(texto, Normalizer.Form.NFKC);
        StringBuilder sb = new StringBuilder(nfkc.length());
        nfkc.codePoints().forEach(cp -> {
            if (cp == '\n' || cp == '\t') {
                sb.appendCodePoint(cp);
                return;
            }
            int tipo = Character.getType(cp);
            if (tipo != Character.CONTROL && tipo != Character.FORMAT) {
                sb.appendCodePoint(cp);
            }
        });
        return sb.toString().strip();
    }

    /** Minusculas, sin marcas diacriticas y con espacios colapsados. */
    static String plegar(String normalizado) {
        String sinTildes = Normalizer.normalize(normalizado.toLowerCase(Locale.ROOT), Normalizer.Form.NFD)
                .replaceAll("\\p{M}+", "");
        return sinTildes.replaceAll("\\s+", " ");
    }

    /**
     * Una misma palabra con letras latinas y cirilicas o griegas: es el truco
     * de los homoglifos ("ignоra" con una о cirilica).
     */
    static boolean mezclaAlfabetos(String texto) {
        boolean latina = false;
        boolean otra = false;
        for (int i = 0; i < texto.length(); ) {
            int cp = texto.codePointAt(i);
            i += Character.charCount(cp);
            if (!Character.isLetter(cp)) {
                latina = false;
                otra = false;
                continue;
            }
            Character.UnicodeScript guion = Character.UnicodeScript.of(cp);
            if (guion == Character.UnicodeScript.LATIN) {
                latina = true;
            } else if (guion == Character.UnicodeScript.CYRILLIC || guion == Character.UnicodeScript.GREEK) {
                otra = true;
            }
            if (latina && otra) {
                return true;
            }
        }
        return false;
    }
}
