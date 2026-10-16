package com.co.eurekatic.aicontrol.agente.memoria;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonSubTypes;
import com.fasterxml.jackson.annotation.JsonTypeInfo;

import java.util.List;
import java.util.Objects;

/**
 * Forma JSON de un mensaje en la memoria de Redis. Es un tipo propio y no el de
 * Spring AI, cuyo formato no es estable entre versiones. El discriminador
 * {@code tipo} dice la variante; los nombres de los campos son los de siempre,
 * para que una clave escrita antes de desplegar siga leyendose.
 *
 * <p>Solo guarda texto y llamadas a herramientas. El razonamiento del modelo
 * nunca entra aqui.
 */
@JsonIgnoreProperties(ignoreUnknown = true)
@JsonTypeInfo(use = JsonTypeInfo.Id.NAME, include = JsonTypeInfo.As.PROPERTY, property = "tipo")
@JsonSubTypes({
        @JsonSubTypes.Type(value = MensajeMemoria.Usuario.class, name = "USER"),
        @JsonSubTypes.Type(value = MensajeMemoria.Asistente.class, name = "ASSISTANT"),
        @JsonSubTypes.Type(value = MensajeMemoria.Sistema.class, name = "SYSTEM"),
        @JsonSubTypes.Type(value = MensajeMemoria.RespuestaHerramienta.class, name = "TOOL")
})
public sealed interface MensajeMemoria
        permits MensajeMemoria.Usuario, MensajeMemoria.Asistente,
        MensajeMemoria.Sistema, MensajeMemoria.RespuestaHerramienta {

    /** Turno del usuario. */
    record Usuario(String texto) implements MensajeMemoria {
        public Usuario {
            texto = Objects.requireNonNullElse(texto, "");
        }
    }

    /**
     * Turno del asistente. Puede no traer texto si solo pide herramientas;
     * entonces {@code texto} queda vacio.
     */
    record Asistente(String texto, List<LlamadaHerramienta> toolCalls) implements MensajeMemoria {
        public Asistente {
            texto = Objects.requireNonNullElse(texto, "");
            toolCalls = List.copyOf(Objects.requireNonNullElse(toolCalls, List.of()));
        }
    }

    /** Instruccion de sistema. */
    record Sistema(String texto) implements MensajeMemoria {
        public Sistema {
            texto = Objects.requireNonNullElse(texto, "");
        }
    }

    /** Resultados de las herramientas que el modelo pidio en el turno anterior. */
    record RespuestaHerramienta(List<ResultadoHerramienta> toolResponses) implements MensajeMemoria {
        public RespuestaHerramienta {
            toolResponses = List.copyOf(Objects.requireNonNullElse(toolResponses, List.of()));
        }
    }

    /** Llamada a una herramienta, con sus argumentos como JSON. */
    record LlamadaHerramienta(String id, String name, String arguments) {
    }

    /** Resultado de una llamada, como JSON. */
    record ResultadoHerramienta(String id, String name, String responseData) {
    }
}
