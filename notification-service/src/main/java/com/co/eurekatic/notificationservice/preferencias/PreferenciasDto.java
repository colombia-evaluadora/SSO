package com.co.eurekatic.notificationservice.preferencias;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.List;

/**
 * Contrato de {@code GET/PUT /notificaciones/preferencias} (front:
 * {@code PreferenciasRow} / {@code PreferenciasPayload}).
 */
public final class PreferenciasDto {

    private PreferenciasDto() { }

    public record TipoRow(
            @JsonProperty("tipo") String tipo,
            @JsonProperty("categoria") String categoria,
            @JsonProperty("etiqueta") String etiqueta,
            @JsonProperty("in_app") boolean inApp,
            @JsonProperty("push") boolean push,
            @JsonProperty("email") boolean email,
            @JsonProperty("silenciable") boolean silenciable,
            @JsonProperty("push_bloqueado") boolean pushBloqueado,
            @JsonProperty("email_bloqueado") boolean emailBloqueado,
            @JsonProperty("silenciado_hasta") String silenciadoHasta) { }

    public record HorarioRow(
            @JsonProperty("activo") boolean activo,
            @JsonProperty("desde") String desde,
            @JsonProperty("hasta") String hasta,
            @JsonProperty("dias") List<Integer> dias,
            @JsonProperty("zona") String zona,
            @JsonProperty("bloqueado") boolean bloqueado) { }

    public record PreferenciasRow(
            @JsonProperty("tipos") List<TipoRow> tipos,
            @JsonProperty("horario_silencioso") HorarioRow horarioSilencioso) { }

    public record TipoPayload(
            @JsonProperty("tipo") String tipo,
            @JsonProperty("push") Boolean push,
            @JsonProperty("email") Boolean email) { }

    public record HorarioPayload(
            @JsonProperty("activo") Boolean activo,
            @JsonProperty("desde") String desde,
            @JsonProperty("hasta") String hasta,
            @JsonProperty("dias") List<Integer> dias) { }

    public record PreferenciasPayload(
            @JsonProperty("tipos") List<TipoPayload> tipos,
            @JsonProperty("horario_silencioso") HorarioPayload horarioSilencioso) { }
}
