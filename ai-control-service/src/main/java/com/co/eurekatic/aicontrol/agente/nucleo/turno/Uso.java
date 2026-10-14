package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import org.springframework.ai.chat.metadata.ChatResponseMetadata;
import org.springframework.ai.chat.metadata.Usage;
import org.springframework.ai.chat.model.ChatResponse;

import java.util.Optional;

/**
 * Tokens consumidos. Son opcionales: el proveedor no siempre los informa. El razonamiento del modelo
 * no se cuenta aqui: Spring AI no lo expone como uso estandar.
 *
 * @param tokensEntrada tokens del prompt, sumados en el turno
 * @param tokensSalida  tokens de la respuesta, sumados en el turno
 */
public record Uso(Optional<Integer> tokensEntrada, Optional<Integer> tokensSalida) {

    public static final Uso NINGUNO = new Uso(Optional.empty(), Optional.empty());

    /** Uso de una llamada al modelo, tal como lo informa el proveedor. */
    public static Uso de(ChatResponse respuesta) {
        Optional<Usage> usage = Optional.ofNullable(respuesta.getMetadata())
                .map(ChatResponseMetadata::getUsage);
        return new Uso(
                usage.map(Usage::getPromptTokens),
                usage.map(Usage::getCompletionTokens));
    }

    public Uso sumar(Uso otro) {
        return new Uso(sumar(tokensEntrada, otro.tokensEntrada), sumar(tokensSalida, otro.tokensSalida));
    }

    private static Optional<Integer> sumar(Optional<Integer> a, Optional<Integer> b) {
        if (a.isEmpty() && b.isEmpty()) {
            return Optional.empty();
        }
        return Optional.of(a.orElse(0) + b.orElse(0));
    }
}
