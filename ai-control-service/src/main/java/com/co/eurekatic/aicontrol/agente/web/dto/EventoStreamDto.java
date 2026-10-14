package com.co.eurekatic.aicontrol.agente.web.dto;

import com.fasterxml.jackson.annotation.JsonInclude;

/**
 * Datos de los eventos {@code estado} y {@code error} del streaming. Los campos que no aplican se omiten.
 *
 * @param estado  paso del turno (EstadoTurno), en eventos de estado
 * @param status  estado HTTP equivalente, en eventos de error
 * @param mensaje texto para la persona, en eventos de error
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
public record EventoStreamDto(String estado, Integer status, String mensaje) {

    public static EventoStreamDto estado(String estado) {
        return new EventoStreamDto(estado, null, null);
    }

    public static EventoStreamDto error(int status, String mensaje) {
        return new EventoStreamDto(null, status, mensaje);
    }
}
