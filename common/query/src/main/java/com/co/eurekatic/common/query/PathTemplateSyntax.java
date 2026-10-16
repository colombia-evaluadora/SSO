package com.co.eurekatic.common.query;

import java.util.LinkedHashSet;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Única fuente de verdad de la sintaxis de plantillas de ruta.
 *
 * <p>Vive en {@code common} a propósito: la validación al guardar
 * (sso-admin) y el matching en tiempo de petición (query-service)
 * tienen que entender exactamente la misma gramática. Si cada lado
 * tuviera su propia copia, una plantilla podría guardarse y luego
 * no resolver — el fallo más caro de diagnosticar que hay aquí,
 * porque no produce error: produce 200 con lista vacía.
 *
 * <p>Gramática: una variable es {@code :} seguido de
 * {@code [A-Z][A-Z0-9_]*}. Las mayúsculas son obligatorias para que
 * una variable se distinga de un literal de un vistazo, y porque
 * los parámetros que inyecta el sistema son todos minúsculas — así
 * una variable de ruta nunca puede pisarlos.
 */
public final class PathTemplateSyntax {

    private PathTemplateSyntax() {}

    /**
     * Un candidato a variable: {@code ':'} y TODO lo que le siga
     * hasta el final del segmento.
     *
     * <p>Deliberadamente permisivo. Un patrón estrecho como
     * {@code [A-Za-z_][A-Za-z0-9_]*} parece más correcto y es una
     * trampa: se corta en el primer carácter no ASCII, de modo que
     * {@code :AÑO} se detecta como la variable {@code A}, pasa la
     * validación, y luego {@code toBracePattern} produce
     * {@code {A}ÑO} — un patrón que sólo casa con rutas acabadas en
     * "ÑO". En un catálogo en español ({@code :AÑO}, {@code :CÓDIGO},
     * {@code :TAMAÑO}) eso no es un caso exótico. Y el síntoma es
     * justo el que esta clase existe para evitar: 200 con lista
     * vacía, nunca un error.
     *
     * <p>Capturando el segmento entero, cualquier cosa que no sea
     * un nombre válido falla ruidosamente en {@link #validate}, y
     * "lo que validate acepta es exactamente lo que toBracePattern
     * traduce bien" pasa a ser estructural en vez de casual.
     */
    private static final Pattern VARIABLE = Pattern.compile(":([^/]*)");

    // El nombre aceptable dentro de una variable NO se define aquí:
    // se delega en ParamNamespace.isValidName, que es la misma regla
    // que se aplica a las claves del query string y del body. Con
    // dos definiciones, una plantilla podría validarse y generar un
    // bind que luego el SQL no puede nombrar.

    /**
     * Valida una plantilla. Lanza {@link IllegalArgumentException}
     * con un mensaje que explica QUÉ hay que escribir, no sólo qué
     * está mal — el consumidor es un admin en un formulario, no un
     * programador leyendo un stacktrace.
     *
     * <p>Asume que el llamante ya normalizó la cadena; sso-admin lo
     * hace en normalizePathTemplate antes de validar y de guardar.
     */
    public static void validate(String template) {
        if (template == null || template.isBlank()) {
            throw new IllegalArgumentException(
                    "La plantilla de ruta no puede estar vacía.");
        }
        String t = template.trim();
        if (!t.startsWith("/")) {
            throw new IllegalArgumentException(
                    "La plantilla debe empezar por '/': " + t);
        }
        // Se rechaza cualquier comodín, no sólo '**'. Un '*' casa un
        // segmento entero y un '?' un carácter en PathPattern, así que
        // /reporte/* daría una ruta comodín donde el admin creía
        // escribir una literal — una cuestión de superficie de
        // autorización, no sólo de matching.
        if (t.indexOf('*') >= 0 || t.indexOf('?') >= 0) {
            throw new IllegalArgumentException(
                    "La plantilla no puede contener comodines ('*' ni '?'). "
                    + "El prefijo con '**' lo aporta el microservicio "
                    + "(MICROSERVICE.REQUEST_URI). Usa una ruta literal, "
                    + "ej /establecimiento/:NOMBRE");
        }
        if (t.indexOf('{') >= 0 || t.indexOf('}') >= 0) {
            throw new IllegalArgumentException(
                    "La sintaxis {variable} ya no se admite. Escribe "
                    + ":VARIABLE en MAYÚSCULA — por ejemplo, en vez de "
                    + "/establecimiento/{nombre} usa /establecimiento/:NOMBRE");
        }
        Set<String> seen = new LinkedHashSet<>();
        Matcher m = VARIABLE.matcher(t);
        while (m.find()) {
            String name = m.group(1);
            if (!ParamNamespace.isValidName(name)) {
                String suggestion = name.toUpperCase(Locale.ROOT);
                throw new IllegalArgumentException(
                        "El nombre de variable ':" + name + "' debe ir en "
                        + "MAYÚSCULA, empezar por letra y usar sólo A-Z, 0-9 "
                        + "y '_'. Translitera acentos y eñe — ':ANIO', no "
                        + "':AÑO'"
                        // Sólo se sugiere una corrección cuando difiere del
                        // original: decirle al admin "usa ':_FOO'" cuando
                        // acaba de escribir ':_FOO' no ayuda a nadie.
                        + (ParamNamespace.isValidName(suggestion)
                                ? ": usa ':" + suggestion + "'"
                                : "."));
            }
            if (!seen.add(name)) {
                throw new IllegalArgumentException(
                        "La variable ':" + name + "' aparece más de una vez "
                        + "en la plantilla.");
            }
        }
    }

    /**
     * Traduce {@code :NOMBRE} a <code>{NOMBRE}</code>, que es la
     * forma que entiende {@code PathPatternParser} de Spring.
     *
     * <p>Es el único punto de traducción del sistema: hacia fuera
     * (catálogo, formulario, documentación) sólo existe {@code :}.
     */
    public static String toBracePattern(String template) {
        if (template == null) {
            return null;
        }
        return VARIABLE.matcher(template).replaceAll("{$1}");
    }
}
