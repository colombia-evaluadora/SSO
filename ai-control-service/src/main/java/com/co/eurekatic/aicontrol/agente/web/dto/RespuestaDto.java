package com.co.eurekatic.aicontrol.agente.web.dto;

import com.co.eurekatic.aicontrol.agente.nucleo.Faltante;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.AccionUi;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.fasterxml.jackson.annotation.JsonInclude;

import java.util.List;
import java.util.Map;

/**
 * Respuesta de un turno tal como la recibe el front. Los campos que no aplican al tipo se omiten.
 */
@JsonInclude(JsonInclude.Include.NON_EMPTY)
public record RespuestaDto(
        String tipo,
        String texto,
        List<FaltanteDto> faltantes,
        AccionPendienteDto accionPendiente,
        List<AccionUi> acciones,
        DatosDto datos) {

    public static RespuestaDto de(RespuestaAgente respuesta) {
        return switch (respuesta) {
            case RespuestaAgente.Pregunta p -> new RespuestaDto(p.tipo().name(), p.texto(),
                    p.faltantes().stream().map(FaltanteDto::de).toList(), null, List.of(), null);
            case RespuestaAgente.Confirmacion c -> new RespuestaDto(c.tipo().name(), c.texto(),
                    List.of(), AccionPendienteDto.de(c.accion()), List.of(), null);
            case RespuestaAgente.Ui u -> new RespuestaDto(u.tipo().name(), u.texto(),
                    List.of(), null, u.acciones(), null);
            case RespuestaAgente.Datos d -> new RespuestaDto(d.tipo().name(), d.texto(),
                    List.of(), null, List.of(), new DatosDto(d.columnas(), d.filas()));
            case RespuestaAgente.Respuesta r -> simple(r);
            case RespuestaAgente.Bloqueado b -> simple(b);
            case RespuestaAgente.SinPermiso s -> simple(s);
        };
    }

    private static RespuestaDto simple(RespuestaAgente respuesta) {
        return new RespuestaDto(respuesta.tipo().name(), respuesta.texto(), List.of(), null, List.of(), null);
    }

    /** Filas y columnas de una respuesta de datos. */
    public record DatosDto(List<String> columnas, List<Map<String, Object>> filas) {
    }
}
