package com.co.eurekatic.aicontrol.agente.nucleo.control;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.estructura.EstructuraEndpoint;
import com.co.eurekatic.aicontrol.agente.nucleo.TurnoContexto;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.stereotype.Component;

import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

/**
 * Herramienta {@code estructura_esperada}: para cualquier herramienta del turno devuelve lo que su endpoint del
 * query-service espera, sin documentarlo a mano. Junta el esquema de argumentos (tipos, obligatorios,
 * restricciones), el contrato del endpoint y, sacado de su propio codigo, las claves JSON que lee cada bloque y los
 * mensajes con los que rechaza un dato. Es la forma de armar un JSON compuesto (un instrumento, una calificacion)
 * sin adivinarlo.
 */
@Component
public class EstructuraEsperadaHerramienta implements ProveedorHerramientasControl {

    static final String NOMBRE = "estructura_esperada";
    static final int MAX_CARACTERES = 6000;
    static final int MAX_VALIDACIONES_POR_BLOQUE = 12;
    private static final Logger log = LoggerFactory.getLogger(EstructuraEsperadaHerramienta.class);

    private static final String DESCRIPCION = """
            Devuelve la estructura que espera el endpoint de una accion o consulta del turno: sus campos con tipo,
            obligatorios y restricciones, el contrato del endpoint y, para los campos JSON compuestos, las claves
            que lee la base en cada variante y los mensajes con que rechaza un dato. Usala antes de armar un JSON
            compuesto (definicion de instrumento, calificacion, adaptaciones, materiales) o tras un rechazo de formato.
            """;

    private static final String ESQUEMA = """
            {"type":"object","additionalProperties":false,"required":["codigo"],"properties":{
              "codigo":{"type":"string","description":"Codigo de la accion o consulta"}}}
            """;

    private final EstructuraEndpoint estructura;
    private final List<ToolCallback> callbacks;

    public EstructuraEsperadaHerramienta(EstructuraEndpoint estructura) {
        this.estructura = estructura;
        this.callbacks = List.of(CallbacksControl.crear(NOMBRE, DESCRIPCION, ESQUEMA, false, this::ejecutar));
    }

    @Override
    public List<ToolCallback> callbacks() {
        return callbacks;
    }

    String ejecutar(Map<String, Object> argumentos, ToolContext contexto) {
        TurnoContexto turno = TurnoContexto.de(contexto);
        Object codigo = argumentos == null ? null : argumentos.get("codigo");
        if (!(codigo instanceof String texto) || texto.isBlank()) {
            return "Indica el codigo de la accion o consulta.";
        }
        return turno.herramienta(texto.trim())
                .map(this::describir)
                .orElse(EsquemaDeAccionHerramienta.NO_DISPONIBLE);
    }

    String describir(HerramientaDef herramienta) {
        StringBuilder salida = new StringBuilder("Campos: ").append(EsquemaDeAccionHerramienta.esquema(herramienta));
        herramienta.detalle().ifPresent(d -> salida.append("\nContrato: ").append(d));
        List<EstructuraEndpoint.Bloque> bloques = bloques(herramienta);
        if (!bloques.isEmpty()) {
            salida.append("\nLo que lee y valida la base, por bloque:");
            bloques.forEach(b -> salida.append("\n- ").append(b.bloque()).append(texto(b)));
        }
        return salida.length() > MAX_CARACTERES ? salida.substring(0, MAX_CARACTERES) + "…" : salida.toString();
    }

    private List<EstructuraEndpoint.Bloque> bloques(HerramientaDef herramienta) {
        if (herramienta.ruta().isEmpty()) {
            return List.of();
        }
        try {
            return estructura.de(herramienta.id());
        } catch (RuntimeException e) {
            // Sin la base, el esquema y el contrato siguen sirviendo.
            log.warn("Estructura del endpoint no disponible para {}: {}", herramienta.codigo(), e.getClass().getSimpleName());
            return List.of();
        }
    }

    private static String texto(EstructuraEndpoint.Bloque bloque) {
        StringBuilder texto = new StringBuilder();
        if (!bloque.claves().isEmpty()) {
            texto.append(": claves ").append(String.join(", ", bloque.claves()));
        }
        if (!bloque.pistas().isEmpty()) {
            texto.append(texto.isEmpty() ? ": " : "; ").append("tipos: ").append(String.join(" | ", bloque.pistas()));
        }
        if (!bloque.validaciones().isEmpty()) {
            texto.append(texto.isEmpty() ? ": " : "; ").append("rechaza si: ").append(bloque.validaciones().stream()
                    .limit(MAX_VALIDACIONES_POR_BLOQUE).collect(Collectors.joining(" | ")));
        }
        return texto.toString();
    }
}
