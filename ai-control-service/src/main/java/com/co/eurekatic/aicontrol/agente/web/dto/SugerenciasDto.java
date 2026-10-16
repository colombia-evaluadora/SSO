package com.co.eurekatic.aicontrol.agente.web.dto;

import com.co.eurekatic.aicontrol.agente.ui.sugerencias.SugerenciasService;
import com.fasterxml.jackson.annotation.JsonInclude;

import java.util.List;

/**
 * Respuesta de {@code GET /sugerencias}.
 *
 * @param pantalla    pantalla reconocida para la ruta; null si ninguna coincide
 * @param sugerencias mensajes listos para enviar, los de la pantalla primero
 * @param capacidades lo que el asistente puede hacer por el usuario
 */
public record SugerenciasDto(@JsonInclude(JsonInclude.Include.NON_NULL) PantallaDto pantalla,
                             List<SugerenciaDto> sugerencias, SugerenciasService.Capacidades capacidades) {

    public static SugerenciasDto de(SugerenciasService.Resultado r) {
        return new SugerenciasDto(
                r.pantalla().map(p -> new PantallaDto(p.codigo(), p.nombre(), p.menuCodigo(), p.url())).orElse(null),
                r.sugerencias().stream().map(s -> new SugerenciaDto(s.texto(), s.tipo().name())).toList(),
                r.capacidades());
    }

    public record PantallaDto(String codigo, String nombre, String menu, String url) {
    }

    /** @param tipo CONSULTA, ACCION, NAVEGACION o AYUDA */
    public record SugerenciaDto(String texto, String tipo) {
    }
}
