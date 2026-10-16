package com.co.eurekatic.aicontrol.agente.web.dto;

import com.co.eurekatic.aicontrol.agente.nucleo.turno.ConversacionesService;
import com.co.eurekatic.aicontrol.agente.persistencia.accion.EstadoAccion;
import com.co.eurekatic.aicontrol.agente.persistencia.conversacion.ConversacionStore.Conversacion;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore.Mensaje;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.RolMensaje;
import com.fasterxml.jackson.annotation.JsonInclude;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Vistas de conversaciones para el front: listado, detalle y el id de una nueva. */
public final class ConversacionesDto {

    private static final JsonMapper JSON = JsonMapper.builder().build();

    private ConversacionesDto() {
    }

    /** Id que devuelve la creacion de una conversacion. */
    public record Creada(UUID conversationId) {
    }

    /** Resultado de cancelar el turno en curso. */
    public record Cancelacion(boolean cancelado) {
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
            return new Detalle(Resumen.de(d.conversacion()),
                    d.mensajes().stream().map(m -> MensajeDto.de(m, d.estadosAccion())).toList());
        }
    }

    /**
     * Un mensaje del historial. {@code respuesta} solo viene en los del asistente: la misma {@code Respuesta}
     * del endpoint de mensajes, con {@code accionPendiente.estado} al dia.
     */
    public record MensajeDto(long id, int secuencia, String rol, String texto,
                             @JsonInclude(JsonInclude.Include.NON_NULL) String tipoRespuesta,
                             LocalDateTime createdAt,
                             @JsonInclude(JsonInclude.Include.NON_NULL) JsonNode respuesta) {

        public static MensajeDto de(Mensaje m) {
            return de(m, Map.of());
        }

        public static MensajeDto de(Mensaje m, Map<UUID, EstadoAccion> estados) {
            return new MensajeDto(m.id(), m.secuencia(), m.rol().name(), m.contenido(), m.tipoRespuesta(), m.createdAt(),
                    respuesta(m, estados));
        }

        /**
         * La respuesta guardada; en mensajes anteriores a la columna se arma con lo que hay (tipo, texto y
         * acciones de UI). Una accion pendiente sin estado conocido (p. ej. ya purgada) se da por EXPIRADA.
         */
        static JsonNode respuesta(Mensaje m, Map<UUID, EstadoAccion> estados) {
            if (m.rol() != RolMensaje.ASSISTANT) {
                return null;
            }
            ObjectNode nodo = leer(m.respuesta());
            if (nodo == null) {
                nodo = JSON.createObjectNode();
                if (m.tipoRespuesta() != null) {
                    nodo.put("tipo", m.tipoRespuesta());
                }
                nodo.put("texto", m.contenido());
                ObjectNode conAcciones = m.accionesUi() == null ? null : leerArreglo(m.accionesUi(), nodo);
                if (conAcciones != null) {
                    nodo = conAcciones;
                }
            }
            JsonNode accion = nodo.get("accionPendiente");
            if (accion instanceof ObjectNode pendiente && pendiente.path("id").isString()) {
                EstadoAccion estado = estadoDe(pendiente.path("id").asString(), estados);
                pendiente.put("estado", estado.name());
            }
            return nodo;
        }

        private static EstadoAccion estadoDe(String id, Map<UUID, EstadoAccion> estados) {
            try {
                return estados.getOrDefault(UUID.fromString(id), EstadoAccion.EXPIRADA);
            } catch (IllegalArgumentException e) {
                return EstadoAccion.EXPIRADA;
            }
        }

        private static ObjectNode leer(String json) {
            if (json == null) {
                return null;
            }
            try {
                return JSON.readTree(json) instanceof ObjectNode objeto ? objeto : null;
            } catch (JacksonException e) {
                return null;
            }
        }

        private static ObjectNode leerArreglo(String json, ObjectNode nodo) {
            try {
                JsonNode acciones = JSON.readTree(json);
                if (acciones.isArray()) {
                    nodo.set("acciones", acciones);
                }
                return nodo;
            } catch (JacksonException e) {
                return null;
            }
        }
    }
}
