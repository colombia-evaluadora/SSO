package com.co.eurekatic.aicontrol.agente.catalogo.carga;

import java.util.Arrays;
import java.util.Optional;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

/**
 * El {@code detail} de {@code public.query} como contexto para el modelo: lo que el endpoint exige, admite y
 * devuelve, sin lo que es de quien lo programa. Se quitan los parentesis que nombran funciones, migraciones o
 * reglas ({@code (fn_unidad_crear)}, {@code (Regla 19)}), los prefijos {@code V245 --} y {@code §4:}, y las
 * frases de gate y de codigos de error. Pura.
 */
public final class DetalleParaModelo {

    /** Tope del texto: el detail mas largo pasa de 2000 caracteres y viaja en cada turno que puede escribir. */
    static final int MAX_CARACTERES = 900;

    private static final Pattern PARENTESIS_INTERNO = Pattern.compile(
            "\\s*\\((?=[^()]*(?:\\bfn_|\\bV\\d|\\bRegla\\b|\\bBloque\\b))[^()]*\\)");
    private static final Pattern PREFIJO_VERSION = Pattern.compile("^\\s*V\\d+(?:\\.\\d+)?(?:/V\\d+(?:\\.\\d+)?)*\\s*--\\s*");
    private static final Pattern SECCION = Pattern.compile("§\\d+:?\\s*");
    private static final Pattern REGLA_SUELTA = Pattern.compile("[;,]?\\s*\\bRegla \\d+[a-z]?\\b");
    private static final Pattern FUNCION = Pattern.compile("\\bfn_[a-z0-9_]+\\b");
    private static final Pattern FIN_DE_FRASE = Pattern.compile("(?<=\\.)\\s+(?=[A-ZÁÉÍÓÚÑ¿:])");
    private static final Pattern FRASE_INTERNA = Pattern.compile(
            "^(?:Errores:|Gate\\b|Retorna PK_|Devuelve PK_|\\d{3} \\(|\\d{5}\\b).*", Pattern.DOTALL);
    /** Una frase con dos versiones cuenta la historia del endpoint ("Entre V414 y V442 ..."), no su contrato. */
    private static final Pattern HISTORIA = Pattern.compile("\\bV\\d+.*\\bV\\d+", Pattern.DOTALL);
    private static final Pattern VERSION_SUELTA = Pattern.compile("\\s*\\bV\\d+(?:\\.\\d+)?\\b(?:\\s*--)?");
    private static final Pattern CODIGO_SQL = Pattern.compile("\\s*\\((?:\\d{5}|P\\d{4})\\)");
    private static final Pattern ESPACIOS = Pattern.compile("\\s{2,}");

    private DetalleParaModelo() {
    }

    public static Optional<String> limpiar(String detail) {
        if (detail == null || detail.isBlank()) {
            return Optional.empty();
        }
        String texto = PREFIJO_VERSION.matcher(detail.strip()).replaceFirst("");
        // La marca de seccion se quita antes: su parentesis lleva contrato ("(§4: si llega, ...)").
        texto = SECCION.matcher(texto).replaceAll("");
        texto = CODIGO_SQL.matcher(texto).replaceAll("");
        texto = PARENTESIS_INTERNO.matcher(texto).replaceAll("");
        texto = REGLA_SUELTA.matcher(texto).replaceAll("");
        String frases = Arrays.stream(FIN_DE_FRASE.split(texto))
                .map(String::strip)
                .filter(frase -> !frase.isEmpty() && !FRASE_INTERNA.matcher(frase).matches()
                        && !FUNCION.matcher(frase).find() && !HISTORIA.matcher(frase).find())
                .map(frase -> VERSION_SUELTA.matcher(frase).replaceAll(""))
                .collect(Collectors.joining(" "));
        String limpio = ESPACIOS.matcher(frases).replaceAll(" ").strip();
        return limpio.isEmpty() ? Optional.empty() : Optional.of(recortar(limpio));
    }

    /** Hasta el ultimo fin de frase que cabe; si ninguna cabe, corta en el tope. */
    private static String recortar(String texto) {
        if (texto.length() <= MAX_CARACTERES) {
            return texto;
        }
        int corte = texto.lastIndexOf(". ", MAX_CARACTERES);
        return corte > MAX_CARACTERES / 2 ? texto.substring(0, corte + 1) : texto.substring(0, MAX_CARACTERES);
    }
}
