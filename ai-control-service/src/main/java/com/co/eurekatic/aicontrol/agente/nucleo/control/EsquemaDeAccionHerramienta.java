package com.co.eurekatic.aicontrol.agente.nucleo.control;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.Restriccion;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.RutaQuery;
import com.co.eurekatic.aicontrol.agente.catalogo.esquema.JsonSchemaBuilder;
import com.co.eurekatic.aicontrol.agente.nucleo.TurnoContexto;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;

/**
 * Herramienta {@code esquema_de_accion}: devuelve el JSON Schema de los argumentos de una herramienta
 * que el modelo ve en este turno. Asi el modelo pregunta solo por los datos que la accion exige.
 */
@Component
public class EsquemaDeAccionHerramienta implements ProveedorHerramientasControl {

    static final String NOMBRE = "esquema_de_accion";
    static final String NO_DISPONIBLE = "La accion pedida no esta disponible en este turno.";

    private static final String DESCRIPCION = """
            Devuelve el JSON Schema de los argumentos de una accion disponible en este turno: campos,
            obligatorios, formatos y de donde sale cada valor. Usala antes de pedir datos para una accion.
            """;

    private static final String ESQUEMA = """
            {"type":"object","additionalProperties":false,"required":["codigo"],"properties":{
              "codigo":{"type":"string","description":"Codigo de la accion o consulta"}}}
            """;

    private final List<ToolCallback> callbacks = List.of(CallbacksControl.crear(
            NOMBRE, DESCRIPCION, ESQUEMA, false, this::ejecutar));

    @Override
    public List<ToolCallback> callbacks() {
        return callbacks;
    }

    String ejecutar(Map<String, Object> argumentos, ToolContext contexto) {
        TurnoContexto turno = TurnoContexto.de(contexto);
        Object codigo = argumentos == null ? null : argumentos.get("codigo");
        if (!(codigo instanceof String texto) || texto.isBlank()) {
            return "Indica el codigo de la accion.";
        }
        return turno.herramienta(texto.trim())
                .map(EsquemaDeAccionHerramienta::esquema)
                .orElse(NO_DISPONIBLE);
    }

    /** Esquema de una herramienta, con las restricciones de su ruta. */
    static String esquema(HerramientaDef herramienta) {
        Map<String, Restriccion> restricciones = herramienta.ruta()
                .map(RutaQuery::restricciones)
                .orElse(Map.of());
        return JsonSchemaBuilder.construir(herramienta.parametros(), restricciones);
    }
}
