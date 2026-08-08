package com.co.eurekatic.common.query;

import java.util.LinkedHashSet;
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

    /** Una variable candidata: dos puntos + identificador. */
    private static final Pattern VARIABLE =
            Pattern.compile(":([A-Za-z_][A-Za-z0-9_]*)");

    /** Nombre aceptable dentro de una variable. */
    private static final Pattern VALID_NAME =
            Pattern.compile("[A-Z][A-Z0-9_]*");

    /**
     * Valida una plantilla. Lanza {@link IllegalArgumentException}
     * con un mensaje que explica QUÉ hay que escribir, no sólo qué
     * está mal — el consumidor es un admin en un formulario, no un
     * programador leyendo un stacktrace.
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
        if (t.contains("**")) {
            throw new IllegalArgumentException(
                    "La plantilla no puede contener '**' — ese prefijo lo "
                    + "aporta el microservicio (MICROSERVICE.REQUEST_URI). "
                    + "Usa una ruta literal, ej /establecimiento/:NOMBRE");
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
            if (!VALID_NAME.matcher(name).matches()) {
                throw new IllegalArgumentException(
                        "El nombre de variable ':" + name + "' debe ir en "
                        + "MAYÚSCULA y empezar por letra: usa ':"
                        + name.toUpperCase() + "'");
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
