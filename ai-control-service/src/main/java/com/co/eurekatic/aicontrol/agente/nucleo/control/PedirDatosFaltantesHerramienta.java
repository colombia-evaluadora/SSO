package com.co.eurekatic.aicontrol.agente.nucleo.control;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ParametroDef;
import com.co.eurekatic.aicontrol.agente.memoria.NotaDeMemoria;
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
import java.util.Set;
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
    static final String TEXTO = NotaDeMemoria.TEXTO_PREGUNTA;
    static final String CONSULTA_ANTES = "Todavia no consultaste nada en este turno y la persona no ve esta pregunta. "
            + "Los resultados de turnos anteriores no los tienes: busca primero lo que se pueda con las consultas que "
            + "resuelven los datos de la accion; despues pregunta solo lo que siga faltando o sea ambiguo, con opciones "
            + "leidas en este turno. Consultas disponibles: ";

    private static final String DESCRIPCION = """
            Ultimo recurso: usala solo despues de consultar. Si a la accion le falta un dato que sale de una consulta
            (grupo, asignatura, unidad, estudiante, catalogo), llama primero a esa consulta. Usala para lo que
            ninguna herramienta da (un texto, una nota, una fecha) o para elegir entre varias opciones reales, y
            pon esas opciones. Termina el turno y muestra a la persona las preguntas. Nunca supongas valores.
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
        Optional<String> sinConsultar = preguntaSinConsultar(turno);
        if (sinConsultar.isPresent()) {
            return sinConsultar.get();
        }
        turno.responderDirecto(pregunta.get());
        return ACUSE;
    }

    /**
     * Preguntar sin haber mirado nada es la forma en que el modelo se rinde: la correccion que se le devuelve, una
     * vez por turno, si hay consultas que resuelven los datos de la accion. Vale tambien para la pregunta escrita
     * como texto: los resultados de turnos anteriores no los tiene, y si nombra opciones sin leer, las inventa.
     */
    public static Optional<String> preguntaSinConsultar(TurnoContexto turno) {
        List<String> consultas = consultasQueResuelven(turno);
        if (turno.lecturas() == 0 && !consultas.isEmpty() && turno.devolverPreguntaUnaVez()) {
            return Optional.of(CONSULTA_ANTES + String.join(", ", consultas) + ".");
        }
        return Optional.empty();
    }

    /**
     * Las consultas del turno de las que salen los datos de sus escrituras ({@code resuelve_con}): lo que el modelo
     * podia mirar antes de preguntar.
     */
    static List<String> consultasQueResuelven(TurnoContexto turno) {
        Set<String> ofrecidas = turno.herramientas().stream()
                .filter(h -> !h.tipo().escribe())
                .map(HerramientaDef::codigo)
                .collect(Collectors.toSet());
        return turno.herramientas().stream()
                .filter(h -> h.tipo().escribe())
                .flatMap(h -> h.parametros().stream())
                .map(ParametroDef::resuelveCon)
                .flatMap(Optional::stream)
                .filter(ofrecidas::contains)
                .distinct()
                .sorted()
                .toList();
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
