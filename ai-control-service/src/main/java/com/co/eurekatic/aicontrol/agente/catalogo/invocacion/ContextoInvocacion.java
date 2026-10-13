package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import org.springframework.ai.chat.model.ToolContext;

import java.util.Map;
import java.util.Objects;
import java.util.function.Consumer;

/**
 * Lo que una herramienta necesita del turno en curso. Viaja en el {@code ToolContext} de Spring
 * AI: quien monta la llamada al modelo pasa {@link #comoMapa()}.
 *
 * @param userId       usuario del JWT (no se envia a query-service: lo resuelve el token)
 * @param bearer       token del usuario, con el que se llama al query-service
 * @param conversationId conversacion, para el registro de ids
 * @param mensajeId    mensaje del usuario ya persistido; las invocaciones cuelgan de el
 * @param textoUsuario  ultimo mensaje del usuario, para la regla de ids
 * @param alProponer    recibe cada escritura validada que espera confirmacion
 */
public record ContextoInvocacion(
        long userId,
        String bearer,
        String conversationId,
        long mensajeId,
        String textoUsuario,
        Consumer<ResultadoHerramienta.RequiereConfirmacion> alProponer) {

    /** Clave bajo la que el contexto viaja en el {@code ToolContext}. */
    public static final String CLAVE = "contextoInvocacion";

    public ContextoInvocacion {
        Objects.requireNonNull(bearer, "bearer");
        Objects.requireNonNull(conversationId, "conversationId");
        Objects.requireNonNull(textoUsuario, "textoUsuario");
        Objects.requireNonNull(alProponer, "alProponer");
    }

    /** Recupera el contexto del {@code ToolContext} de una llamada. Lanza si falta: es un fallo de cableado. */
    public static ContextoInvocacion de(ToolContext contexto) {
        if (contexto != null && contexto.getContext().get(CLAVE) instanceof ContextoInvocacion ctx) {
            return ctx;
        }
        throw new IllegalStateException("falta el ContextoInvocacion en el ToolContext de la llamada");
    }

    /** Mapa para {@code ToolContext}. */
    public Map<String, Object> comoMapa() {
        return Map.of(CLAVE, this);
    }

    /** Sin el token ni el texto del usuario: un log o un volcado no los expone. */
    @Override
    public String toString() {
        return "ContextoInvocacion[userId=" + userId + ", conversationId=" + conversationId
                + ", mensajeId=" + mensajeId + "]";
    }
}
