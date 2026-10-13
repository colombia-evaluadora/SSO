package com.co.eurekatic.aicontrol.agente.catalogo.dominio;

import org.springframework.http.HttpMethod;

import java.util.Map;
import java.util.Objects;

/**
 * Ruta de query-service que ejecuta una herramienta, tal como la registra {@code public.query}.
 *
 * @param metodo       verbo HTTP
 * @param pathTemplate plantilla con {@code :X} para cada {@code PARAM.X}
 * @param paramTypes   tipo SQL de cada clave canonica, con su sufijo de obligatoriedad
 * @param restricciones limites por clave canonica (de {@code query_param_constraint})
 */
public record RutaQuery(
        HttpMethod metodo,
        String pathTemplate,
        Map<String, String> paramTypes,
        Map<String, Restriccion> restricciones) {

    public RutaQuery {
        Objects.requireNonNull(metodo, "metodo");
        Objects.requireNonNull(pathTemplate, "pathTemplate");
        if (!pathTemplate.startsWith("/")) {
            throw new IllegalArgumentException("pathTemplate debe empezar por /: " + pathTemplate);
        }
        paramTypes = Map.copyOf(paramTypes);
        restricciones = Map.copyOf(restricciones);
    }
}
