package com.co.eurekatic.aicontrol.agente.nucleo.control;

import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.ai.tool.function.FunctionToolCallback;
import org.springframework.ai.tool.metadata.ToolMetadata;
import org.springframework.core.ParameterizedTypeReference;

import java.util.Map;
import java.util.function.BiFunction;

/**
 * Construye los {@link ToolCallback} de control con un esquema propio. El resultado va al modelo como
 * texto plano, no como JSON entrecomillado.
 */
public final class CallbacksControl {

    private CallbacksControl() {
    }

    public static ToolCallback crear(String nombre, String descripcion, String esquema, boolean devuelveDirecto,
                              BiFunction<Map<String, Object>, ToolContext, String> funcion) {
        return FunctionToolCallback.builder(nombre, funcion)
                .description(descripcion)
                .inputSchema(esquema)
                .inputType(new ParameterizedTypeReference<Map<String, Object>>() {})
                .toolMetadata(ToolMetadata.builder().returnDirect(devuelveDirecto).build())
                .toolCallResultConverter((resultado, tipo) -> String.valueOf(resultado))
                .build();
    }
}
