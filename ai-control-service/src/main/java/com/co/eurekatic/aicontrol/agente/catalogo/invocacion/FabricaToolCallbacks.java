package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.Restriccion;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.RutaQuery;
import com.co.eurekatic.aicontrol.agente.catalogo.esquema.JsonSchemaBuilder;
import com.co.eurekatic.aicontrol.agente.seguridad.seudonimos.TablaSeudonimos;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.ai.tool.function.FunctionToolCallback;
import org.springframework.ai.tool.metadata.ToolMetadata;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.stereotype.Component;

import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * Convierte herramientas del catalogo en {@link ToolCallback} de Spring AI. Cada callback
 * recibe los argumentos del modelo, los pasa por el {@link InvocadorHerramientas} con el
 * {@link ContextoInvocacion} del {@code ToolContext} y devuelve el texto formateado.
 *
 * <p>Solo se fabrican callbacks para herramientas de datos (LECTURA, ANALITICA, ESCRITURA).
 * Las de control las implementa el agente con {@code @Tool}.
 */
@Component
public class FabricaToolCallbacks {

    private final InvocadorHerramientas invocador;
    private final FormateadorResultado formateador;

    public FabricaToolCallbacks(InvocadorHerramientas invocador, FormateadorResultado formateador) {
        this.invocador = invocador;
        this.formateador = formateador;
    }

    /** Si la herramienta tiene un callback de datos: lecturas, analitica y escrituras. */
    public static boolean ejecutable(HerramientaDef herramienta) {
        return herramienta.tipo().ejecutaContraQueryService() || herramienta.tipo().escribe();
    }

    /** Callbacks de las herramientas de datos de la lista; las demas se descartan en silencio. */
    public List<ToolCallback> crearTodas(Collection<HerramientaDef> herramientas) {
        return herramientas.stream()
                .filter(FabricaToolCallbacks::ejecutable)
                .map(this::crear)
                .toList();
    }

    /**
     * @throws IllegalArgumentException si la herramienta no es de datos
     */
    public ToolCallback crear(HerramientaDef herramienta) {
        if (!ejecutable(herramienta)) {
            throw new IllegalArgumentException("herramienta sin callback de datos: " + herramienta.codigo());
        }
        Map<String, Restriccion> restricciones = herramienta.ruta()
                .map(RutaQuery::restricciones)
                .orElse(Map.of());
        String esquema = JsonSchemaBuilder.construir(herramienta.parametros(), restricciones);
        return FunctionToolCallback.builder(herramienta.codigo(),
                        (Map<String, Object> argumentos, ToolContext contexto) ->
                                ejecutar(herramienta, argumentos == null ? Map.<String, Object>of() : argumentos,
                                        contexto))
                .description(herramienta.descripcion())
                .inputSchema(esquema)
                // El texto va al modelo tal cual: el conversor por defecto lo envolveria en comillas JSON.
                .toolCallResultConverter((resultado, tipo) -> String.valueOf(resultado))
                .inputType(new ParameterizedTypeReference<Map<String, Object>>() {})
                .toolMetadata(ToolMetadata.builder().returnDirect(herramienta.tipo().devuelveDirecto()).build())
                .build();
    }

    /**
     * Invoca con los nombres reales, avisa al observador del turno con el resultado real (la tabla que ve
     * la persona) y formatea para el modelo con los nombres cambiados por sus seudonimos.
     */
    private String ejecutar(HerramientaDef herramienta, Map<String, Object> argumentos, ToolContext contexto) {
        Optional<TablaSeudonimos> seudonimos = TablaSeudonimos.de(contexto);
        Map<String, Object> reales = seudonimos.map(t -> revelar(t, argumentos)).orElse(argumentos);
        ResultadoHerramienta resultado = invocador.invocar(herramienta, reales, ContextoInvocacion.de(contexto));
        ObservadorResultados.de(contexto).ifPresent(o -> o.alObtener(herramienta, resultado));
        ResultadoHerramienta paraModelo = seudonimos.map(t -> ocultar(t, resultado)).orElse(resultado);
        return formateador.paraModelo(herramienta, paraModelo);
    }

    private static Map<String, Object> revelar(TablaSeudonimos tabla, Map<String, Object> argumentos) {
        Map<String, Object> reales = new LinkedHashMap<>();
        argumentos.forEach((clave, valor) -> reales.put(clave, tabla.revelarValor(valor)));
        return reales;
    }

    static ResultadoHerramienta ocultar(TablaSeudonimos tabla, ResultadoHerramienta resultado) {
        return switch (resultado) {
            case ResultadoHerramienta.Datos datos ->
                    new ResultadoHerramienta.Datos(tabla.ocultarFilas(datos.filas()), datos.truncado());
            case ResultadoHerramienta.ErrorParaModelo error -> new ResultadoHerramienta.ErrorParaModelo(tabla.ocultar(error.texto()));
            case ResultadoHerramienta.RequiereConfirmacion confirmacion -> new ResultadoHerramienta.RequiereConfirmacion(
                    confirmacion.argumentos(), tabla.ocultar(confirmacion.resumen()));
        };
    }
}
