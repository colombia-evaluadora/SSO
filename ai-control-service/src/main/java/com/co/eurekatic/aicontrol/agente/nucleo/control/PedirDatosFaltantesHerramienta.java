package com.co.eurekatic.aicontrol.agente.nucleo.control;

import com.co.eurekatic.aicontrol.agente.nucleo.Faltante;
import com.co.eurekatic.aicontrol.agente.nucleo.TurnoContexto;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.stream.Collectors;

/**
 * Herramienta {@code pedir_datos_faltantes}: el modelo la usa cuando no puede completar una accion sin
 * preguntar. Es {@code returnDirect}: la pregunta llega a la persona y el turno termina; la respuesta
 * llega en el siguiente mensaje.
 */
@Component
public class PedirDatosFaltantesHerramienta implements ProveedorHerramientasControl {

    static final String NOMBRE = "pedir_datos_faltantes";
    static final String ACUSE = "Pregunta enviada a la persona. No hagas mas llamadas en este turno.";
    static final String ERROR = "Indica al menos un dato faltante, con su campo y su pregunta.";
    static final String TEXTO = "Para continuar necesito estos datos.";

    private static final String DESCRIPCION = """
            Usala cuando falten datos obligatorios para una accion y no puedas deducirlos con certeza.
            Termina el turno y muestra a la persona las preguntas. Nunca supongas valores en su lugar.
            """;

    private static final String ESQUEMA = """
            {"type":"object","additionalProperties":false,"required":["faltantes"],"properties":{
              "faltantes":{"type":"array","minItems":1,"items":{"type":"object","additionalProperties":false,
                "required":["campo","pregunta"],"properties":{
                  "campo":{"type":"string","description":"Nombre del dato que falta"},
                  "pregunta":{"type":"string","description":"Pregunta para la persona"},
                  "opciones":{"type":"array","items":{"type":"string"},"description":"Valores posibles, si los hay"}}}},
              "borrador":{"type":"object","description":"Datos ya conocidos de la accion"}}}
            """;

    private final List<ToolCallback> callbacks = List.of(CallbacksControl.crear(
            NOMBRE, DESCRIPCION, ESQUEMA, true, this::ejecutar));

    @Override
    public List<ToolCallback> callbacks() {
        return callbacks;
    }

    String ejecutar(Map<String, Object> argumentos, ToolContext contexto) {
        TurnoContexto turno = TurnoContexto.de(contexto);
        Optional<RespuestaAgente.Pregunta> pregunta = leer(argumentos == null ? Map.of() : argumentos);
        if (pregunta.isEmpty()) {
            return ERROR;
        }
        turno.responderDirecto(pregunta.get());
        return ACUSE;
    }

    /** Lee los argumentos del modelo. Vacio si la forma no es valida: el modelo debe corregirla. */
    static Optional<RespuestaAgente.Pregunta> leer(Map<String, Object> argumentos) {
        if (!(argumentos.get("faltantes") instanceof List<?> lista) || lista.isEmpty()) {
            return Optional.empty();
        }
        List<Faltante> faltantes = new ArrayList<>();
        for (Object elemento : lista) {
            Optional<Faltante> faltante = faltante(elemento);
            if (faltante.isEmpty()) {
                return Optional.empty();
            }
            faltantes.add(faltante.get());
        }
        Map<String, Object> borrador = argumentos.get("borrador") instanceof Map<?, ?> mapa ? borrador(mapa) : Map.of();
        return Optional.of(new RespuestaAgente.Pregunta(TEXTO, faltantes, borrador));
    }

    private static Optional<Faltante> faltante(Object elemento) {
        if (!(elemento instanceof Map<?, ?> mapa)) {
            return Optional.empty();
        }
        if (!(mapa.get("campo") instanceof String campo) || campo.isBlank()) {
            return Optional.empty();
        }
        if (!(mapa.get("pregunta") instanceof String pregunta) || pregunta.isBlank()) {
            return Optional.empty();
        }
        List<String> opciones = mapa.get("opciones") instanceof List<?> lista
                ? lista.stream().filter(String.class::isInstance).map(String.class::cast).toList()
                : List.of();
        return Optional.of(new Faltante(campo.trim(), pregunta.trim(), opciones));
    }

    /** Sin claves ni valores nulos: lo que llega del modelo no puede romper la respuesta. */
    private static Map<String, Object> borrador(Map<?, ?> crudo) {
        Map<String, Object> limpio = crudo.entrySet().stream()
                .filter(e -> e.getKey() instanceof String && e.getValue() != null)
                .collect(Collectors.toMap(e -> (String) e.getKey(), Map.Entry::getValue,
                        (a, b) -> a, LinkedHashMap::new));
        return Map.copyOf(limpio);
    }
}
