package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ParametroDef;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * Textos que se guardan o se muestran sobre una invocacion. Pura.
 *
 * <p>El registro de auditoria guarda solo los nombres de los argumentos, nunca sus valores:
 * un valor es un dato del alumno. El resumen de confirmacion, en cambio, lleva los valores
 * porque el usuario debe ver lo que confirma.
 */
public final class Redaccion {

    private static final JsonMapper JSON = JsonMapper.builder().build();

    private Redaccion() {
    }

    /**
     * Claves que mando el modelo y que estan en el esquema, mas cuantas se descartaron. Una
     * clave desconocida no se guarda: podria ser texto libre con instrucciones.
     */
    public static String clavesJson(Map<String, Object> crudo, Set<String> nombresDelEsquema) {
        List<String> conocidas = crudo.keySet().stream()
                .filter(nombresDelEsquema::contains)
                .sorted()
                .toList();
        ObjectNode nodo = JSON.createObjectNode();
        ArrayNode claves = nodo.putArray("claves");
        conocidas.forEach(claves::add);
        nodo.put("descartadas", crudo.size() - conocidas.size());
        return JSON.writeValueAsString(nodo);
    }

    /** Lo que el usuario confirma: la descripcion de la herramienta y cada valor con su etiqueta. */
    public static String resumenPropuesta(HerramientaDef herramienta, ArgumentosCanonicos argumentos) {
        String pares = herramienta.parametros().stream()
                .filter(p -> argumentos.planos().containsKey(p.clave()))
                .map(p -> etiqueta(p) + ": " + texto(argumentos.planos().get(p.clave())))
                .collect(Collectors.joining("; "));
        return pares.isEmpty() ? herramienta.descripcion() : herramienta.descripcion() + " - " + pares;
    }

    private static String etiqueta(ParametroDef parametro) {
        return parametro.descripcion().isBlank() ? parametro.clave() : parametro.descripcion();
    }

    private static String texto(Object valor) {
        return valor instanceof List<?> lista
                ? lista.stream().map(String::valueOf).collect(Collectors.joining(", "))
                : String.valueOf(valor);
    }
}
