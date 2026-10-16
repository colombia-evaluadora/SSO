package com.co.eurekatic.aicontrol.agente.web.dto;

import com.co.eurekatic.aicontrol.agente.nucleo.Faltante;
import com.fasterxml.jackson.annotation.JsonInclude;

import java.util.List;

/** Un dato que falta y su pregunta. */
public record FaltanteDto(
        String campo,
        String pregunta,
        @JsonInclude(JsonInclude.Include.NON_EMPTY) List<String> opciones) {

    public static FaltanteDto de(Faltante faltante) {
        return new FaltanteDto(faltante.campo(), faltante.pregunta(), faltante.opciones());
    }
}
