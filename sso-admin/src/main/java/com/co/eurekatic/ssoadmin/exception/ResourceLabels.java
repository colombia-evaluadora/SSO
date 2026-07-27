package com.co.eurekatic.ssoadmin.exception;

import java.util.Map;

/**
 * Traduce el token técnico de recurso que usan los servicios
 * ({@code "App"}, {@code "Role"}, …) a una frase nominal en
 * español, para que los mensajes que ve la persona usuaria en
 * admin-ui salgan en su idioma.
 *
 * <p><b>Por qué aquí y no en cada sitio de llamada:</b> los
 * tokens aparecen en ~90 {@code orElseThrow(...)} repartidos
 * por los servicios. Centralizarlos deja el código de negocio
 * en su vocabulario técnico (que coincide con el nombre de la
 * entidad JPA) y concentra el texto de cara al usuario en un
 * único punto — el mismo sitio al que habría que volver si
 * algún día se añade un segundo idioma.
 *
 * <p>Un token desconocido se devuelve tal cual, así que un
 * sitio de llamada puede pasar directamente una frase en
 * español cuando el recurso no tenga entidad propia (p. ej.
 * {@code "el contenedor del microservicio"}).
 */
final class ResourceLabels {

    private static final Map<String, String> LABELS = Map.ofEntries(
            Map.entry("App", "la aplicación"),
            Map.entry("Role", "el rol"),
            Map.entry("User", "el usuario"),
            Map.entry("Route", "la ruta"),
            Map.entry("Group", "el grupo"),
            Map.entry("Endpoint", "el endpoint"),
            Map.entry("Query", "la consulta"),
            Map.entry("Microservice", "el microservicio"),
            Map.entry("Microservice.instanceName", "el microservicio con instanceName"),
            Map.entry("WriteDefinition", "la definición de escritura"));

    private ResourceLabels() {
    }

    static String of(String resource) {
        if (resource == null) {
            return "el recurso";
        }
        return LABELS.getOrDefault(resource, resource);
    }
}
