package com.co.eurekatic.aicontrol.agente.web.dto;

import com.co.eurekatic.aicontrol.agente.nucleo.turno.EventoHerramienta;
import com.fasterxml.jackson.annotation.JsonInclude;

/**
 * Datos del evento {@code herramienta} del streaming. Sin argumentos ni resultado.
 *
 * @param id          une el INICIO con su FIN dentro del turno ("h1", "h2"...)
 * @param herramienta codigo de la herramienta
 * @param etiqueta    texto para mostrar ("Consultando sedes")
 * @param fase        INICIO o FIN
 * @param ok          solo en FIN: si termino sin error
 */
@JsonInclude(JsonInclude.Include.NON_NULL)
public record EventoHerramientaDto(String id, String herramienta, String etiqueta, String fase, Boolean ok) {

    public static EventoHerramientaDto de(EventoHerramienta evento) {
        return new EventoHerramientaDto(evento.id(), evento.herramienta(), evento.etiqueta(), evento.fase().name(),
                evento.ok());
    }
}
