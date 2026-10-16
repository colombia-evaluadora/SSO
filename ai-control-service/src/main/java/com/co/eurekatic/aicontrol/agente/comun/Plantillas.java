package com.co.eurekatic.aicontrol.agente.comun;

import com.co.eurekatic.aicontrol.agente.seguridad.salida.SalidaSegura;
import org.springframework.core.io.Resource;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;

/**
 * Carga de los prompts del agente. Toda plantilla lleva el marcador {@code {{canario}}}, que se
 * sustituye por {@link SalidaSegura#CANARIO}: si el canario sale en una respuesta, el prompt se filtro.
 */
public final class Plantillas {

    private static final String MARCA_CANARIO = "{{canario}}";

    private Plantillas() {
    }

    public static String cargar(Resource plantilla) {
        try {
            return plantilla.getContentAsString(StandardCharsets.UTF_8).replace(MARCA_CANARIO, SalidaSegura.CANARIO);
        } catch (IOException e) {
            throw new UncheckedIOException("No se pudo leer la plantilla " + plantilla.getDescription(), e);
        }
    }
}
