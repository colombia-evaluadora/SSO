package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import org.springframework.ai.chat.model.ToolContext;

import java.util.Map;
import java.util.Optional;

/**
 * Puerto: quien monta el turno puede enterarse de lo que devuelve cada herramienta de datos (p. ej. para
 * presentar una tabla de analitica) sin que el catalogo dependa del nucleo. Viaja, opcional, en el
 * {@code ToolContext}.
 */
@FunctionalInterface
public interface ObservadorResultados {

    /** Clave bajo la que el observador viaja en el {@code ToolContext}. */
    String CLAVE = "observadorResultados";

    void alObtener(HerramientaDef herramienta, ResultadoHerramienta resultado);

    /** Cada llamada a una escritura, aceptada o rechazada, con los argumentos tal como los mando el modelo. */
    default void alIntentarEscritura(HerramientaDef herramienta, Map<String, Object> argumentosDelModelo) {
    }

    static Optional<ObservadorResultados> de(ToolContext contexto) {
        return contexto != null && contexto.getContext().get(CLAVE) instanceof ObservadorResultados observador
                ? Optional.of(observador)
                : Optional.empty();
    }
}
