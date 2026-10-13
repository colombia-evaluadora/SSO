package com.co.eurekatic.aicontrol.agente.catalogo.esquema;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ParametroDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.Restriccion;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoSql;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

import java.util.List;
import java.util.Map;

/**
 * Construye el JSON Schema (draft 2020-12) de los argumentos de una herramienta a partir de
 * sus parametros y de sus restricciones. Pura: sin estado ni I/O.
 *
 * <p>{@code additionalProperties: false}: lo que el modelo invente fuera del esquema no llega
 * al invocador. Cada propiedad lleva su descripcion y, si la tiene, de donde sale su valor.
 */
public final class JsonSchemaBuilder {

    private static final JsonMapper JSON = JsonMapper.builder().build();
    static final String DRAFT = "https://json-schema.org/draft/2020-12/schema";

    private JsonSchemaBuilder() {
    }

    /**
     * @param parametros    allowlist de la herramienta, ya tipada
     * @param restricciones restricciones por clave canonica; las ausentes son sin limites
     * @return el esquema como JSON, listo para {@code FunctionToolCallback.inputSchema}
     */
    public static String construir(List<ParametroDef> parametros, Map<String, Restriccion> restricciones) {
        NombresParametro nombres = NombresParametro.de(parametros);
        ObjectNode raiz = JSON.createObjectNode();
        raiz.put("$schema", DRAFT);
        raiz.put("type", "object");
        raiz.put("additionalProperties", false);
        ObjectNode propiedades = raiz.putObject("properties");
        ArrayNode requeridos = raiz.putArray("required");
        for (ParametroDef parametro : parametros) {
            String nombre = nombres.nombreModelo(parametro.clave());
            Restriccion restriccion = restricciones.getOrDefault(parametro.clave(), Restriccion.sinLimites());
            propiedades.set(nombre, propiedad(parametro, restriccion));
            if (parametro.obligatorio()) {
                requeridos.add(nombre);
            }
        }
        return JSON.writeValueAsString(raiz);
    }

    private static ObjectNode propiedad(ParametroDef parametro, Restriccion restriccion) {
        ObjectNode nodo = JSON.createObjectNode();
        if (parametro.tipo().lista()) {
            nodo.put("type", "array");
            escalar(nodo.putObject("items"), parametro.tipo().base(), restriccion);
        } else {
            escalar(nodo, parametro.tipo().base(), restriccion);
        }
        nodo.put("description", descripcion(parametro));
        return nodo;
    }

    private static void escalar(ObjectNode nodo, TipoSql tipo, Restriccion restriccion) {
        nodo.put("type", tipo.jsonType());
        if (tipo.formato() != null) {
            nodo.put("format", tipo.formato());
        }
        if (!tipo.valores().isEmpty()) {
            ArrayNode valores = nodo.putArray("enum");
            tipo.valores().forEach(valores::add);
        }
        if (tipo == TipoSql.ENTERO || tipo == TipoSql.NUMERICO) {
            limitesNumericos(nodo, tipo, restriccion);
        }
        if ("string".equals(tipo.jsonType())) {
            limitesDeTexto(nodo, restriccion);
        }
    }

    private static void limitesNumericos(ObjectNode nodo, TipoSql tipo, Restriccion restriccion) {
        restriccion.minimo(tipo).ifPresent(l -> {
            if (l.exclusivo()) {
                nodo.put("exclusiveMinimum", l.valor());
            } else {
                nodo.put("minimum", l.valor());
            }
        });
        restriccion.maximo(tipo).ifPresent(l -> nodo.put("maximum", l.valor()));
        if (tipo == TipoSql.NUMERICO && restriccion.soloEnteros()) {
            nodo.put("multipleOf", 1);
        }
    }

    private static void limitesDeTexto(ObjectNode nodo, Restriccion restriccion) {
        restriccion.minLongitud().ifPresent(n -> nodo.put("minLength", n));
        restriccion.maxLongitud().ifPresent(n -> nodo.put("maxLength", n));
        restriccion.patron().ifPresent(p -> nodo.put("pattern", p));
    }

    private static String descripcion(ParametroDef parametro) {
        String base = parametro.descripcion().trim();
        return parametro.resuelveCon()
                .map(herramienta -> (base + " (se obtiene con " + herramienta + ")").trim())
                .orElse(base);
    }
}
