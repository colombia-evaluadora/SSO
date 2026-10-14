package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import org.springframework.http.HttpMethod;

import java.util.Map;
import java.util.Objects;

/**
 * Peticion lista para el query-service.
 *
 * @param metodo verbo HTTP
 * @param ruta   path con los {@code PARAM} ya sustituidos y codificados
 * @param query  binds de query string, sin codificar (la codifica el cliente)
 * @param body   cuerpo anidado; vacio en GET
 */
public record Peticion(HttpMethod metodo, String ruta, Map<String, String> query, Map<String, Object> body) {

    public Peticion {
        Objects.requireNonNull(metodo, "metodo");
        Objects.requireNonNull(ruta, "ruta");
        query = Map.copyOf(query);
        body = Map.copyOf(body);
    }
}
