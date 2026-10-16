package com.co.eurekatic.notificationservice.bandeja;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.List;
import java.util.UUID;

/**
 * Fila de la bandeja tal como la consume el front ({@code NotificacionRow} en
 * {@code src/features/notificaciones/api/types.ts}): snake_case, fechas ISO-8601.
 */
public record NotificacionFila(
        @JsonProperty("id") UUID id,
        @JsonProperty("tipo") String tipo,
        @JsonProperty("categoria") String categoria,
        @JsonProperty("titulo") String titulo,
        @JsonProperty("cuerpo_corto") String cuerpoCorto,
        @JsonProperty("deep_link") String deepLink,
        @JsonProperty("prioridad") String prioridad,
        @JsonProperty("creada_en") String creadaEn,
        @JsonProperty("leida_en") String leidaEn,
        @JsonProperty("actores") List<String> actores,
        @JsonProperty("conteo") Integer conteo) {
}
