package com.co.eurekatic.aicontrol.agente.web.dto;

import com.co.eurekatic.aicontrol.agente.nucleo.turno.ConversacionesService;
import com.co.eurekatic.aicontrol.agente.persistencia.conversacion.ConversacionStore.Conversacion;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore.Mensaje;
import com.fasterxml.jackson.annotation.JsonInclude;

import java.time.LocalDateTime;
import java.util.List;
import java.util.UUID;

/** Vistas de conversaciones para el front: listado, detalle y el id de una nueva. */
public final class ConversacionesDto {

    private ConversacionesDto() {
    }

    /** Id que devuelve la creacion de una conversacion. */
    public record Creada(UUID conversationId) {
    }

    /** Una conversacion en el listado. */
    public record Resumen(UUID id, String titulo, String estado, LocalDateTime ultimoMensajeAt, LocalDateTime createdAt) {

        public static Resumen de(Conversacion c) {
            return new Resumen(c.id(), c.titulo(), c.estado().name(), c.ultimoMensajeAt(), c.createdAt());
        }
    }

    /** Conversacion con sus mensajes. */
    public record Detalle(Resumen conversacion, List<MensajeDto> mensajes) {

        public static Detalle de(ConversacionesService.Detalle d) {
            return new Detalle(Resumen.de(d.conversacion()), d.mensajes().stream().map(MensajeDto::de).toList());
        }
    }

    /** Un mensaje del historial. */
    public record MensajeDto(long id, int secuencia, String rol, String texto,
                             @JsonInclude(JsonInclude.Include.NON_NULL) String tipoRespuesta,
                             LocalDateTime createdAt) {

        public static MensajeDto de(Mensaje m) {
            return new MensajeDto(m.id(), m.secuencia(), m.rol().name(), m.contenido(), m.tipoRespuesta(), m.createdAt());
        }
    }
}
