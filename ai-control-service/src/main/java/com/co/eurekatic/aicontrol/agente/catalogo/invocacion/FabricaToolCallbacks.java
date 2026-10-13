package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.Restriccion;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.RutaQuery;
import com.co.eurekatic.aicontrol.agente.catalogo.esquema.JsonSchemaBuilder;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.ai.tool.function.FunctionToolCallback;
import org.springframework.ai.tool.metadata.ToolMetadata;
import org.springframework.core.ParameterizedTypeReference;
import org.springframework.stereotype.Component;

import java.util.Collection;
import java.util.List;
import java.util.Map;

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
                        (Map<String, Object> argumentos, ToolContext contexto) -> formateador.paraModelo(
                                herramienta,
                                invocador.invocar(herramienta,
                                        argumentos == null ? Map.of() : argumentos,
                                        ContextoInvocacion.de(contexto))))
                .description(herramienta.descripcion())
                .inputSchema(esquema)
                // El texto va al modelo tal cual: el conversor por defecto lo envolveria en comillas JSON.
                .toolCallResultConverter((resultado, tipo) -> String.valueOf(resultado))
                .inputType(new ParameterizedTypeReference<Map<String, Object>>() {})
                .toolMetadata(ToolMetadata.builder().returnDirect(herramienta.tipo().devuelveDirecto()).build())
                .build();
    }
}
