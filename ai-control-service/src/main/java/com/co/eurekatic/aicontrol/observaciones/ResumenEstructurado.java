package com.co.eurekatic.aicontrol.observaciones;

import com.fasterxml.jackson.annotation.JsonPropertyDescription;

import java.util.List;

/**
 * Lo que se le pide al modelo. Se pide estructura y no texto libre para que
 * la forma del informe la decida el servicio ({@link ResumenRenderer}) y no
 * cambie de un estudiante a otro segun el humor del modelo.
 */
public record ResumenEstructurado(
        @JsonPropertyDescription("Parrafo introductorio de 2 a 3 oraciones con la valoracion general del proceso.")
        String introduccion,
        @JsonPropertyDescription("Una entrada por cada dimension del desarrollo que las observaciones permitan valorar. Omitir las dimensiones sin evidencia.")
        List<Dimension> dimensiones,
        @JsonPropertyDescription("Fortalezas evidenciadas, frases breves.")
        List<String> fortalezas,
        @JsonPropertyDescription("Aspectos por fortalecer redactados en positivo, frases breves.")
        List<String> aspectosPorFortalecer,
        @JsonPropertyDescription("Recomendaciones concretas para acompanar desde el hogar.")
        List<String> recomendaciones,
        @JsonPropertyDescription("Oracion de cierre, alentadora.")
        String sintesis) {

    public record Dimension(
            @JsonPropertyDescription("Nombre de la dimension, p. ej. Comunicativa.")
            String nombre,
            @JsonPropertyDescription("Descripcion consolidada de los avances en esa dimension.")
            String descripcion) {}
}
