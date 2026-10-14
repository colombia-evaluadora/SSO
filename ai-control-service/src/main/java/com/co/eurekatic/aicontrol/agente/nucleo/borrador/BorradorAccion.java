package com.co.eurekatic.aicontrol.agente.nucleo.borrador;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ParametroDef;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.Redaccion;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;
import java.util.stream.Collectors;

/**
 * La escritura que el modelo esta armando en la conversacion: la herramienta y los argumentos que ya resolvio,
 * tal como los mando (con seudonimos). Entre turnos el modelo solo conserva texto; sin esto vuelve a consultar
 * todo y pierde lo acordado. Pura.
 */
public record BorradorAccion(String herramienta, Map<String, Object> argumentos) {

    public BorradorAccion {
        Objects.requireNonNull(herramienta, "herramienta");
        argumentos = Map.copyOf(argumentos);
    }

    /** Solo los parametros de la herramienta con valor: lo que el modelo invento o dejo vacio no se arrastra. */
    public static BorradorAccion de(HerramientaDef herramienta, Map<String, Object> argumentos) {
        Map<String, Object> resueltos = new LinkedHashMap<>();
        herramienta.parametros().stream()
                .map(ParametroDef::clave)
                .filter(argumentos::containsKey)
                .forEach(clave -> {
                    Object valor = argumentos.get(clave);
                    if (valor != null && !String.valueOf(valor).isBlank()) {
                        resueltos.put(clave, valor);
                    }
                });
        return new BorradorAccion(herramienta.codigo(), resueltos);
    }

    /** El intento nuevo de la misma herramienta completa el anterior; el de otra lo reemplaza. */
    public BorradorAccion seguidoDe(BorradorAccion nuevo) {
        if (!herramienta.equals(nuevo.herramienta)) {
            return nuevo;
        }
        Map<String, Object> juntos = new LinkedHashMap<>(argumentos);
        juntos.putAll(nuevo.argumentos);
        return new BorradorAccion(herramienta, juntos);
    }

    /** Nota para el mensaje del turno, con la etiqueta de cada campo; vacia si la herramienta no se ofrece. */
    public String nota(HerramientaDef def) {
        if (argumentos.isEmpty()) {
            return "";
        }
        String campos = def.parametros().stream()
                .filter(p -> argumentos.containsKey(p.clave()))
                .map(p -> Redaccion.etiqueta(p) + " [" + p.clave() + "] = " + argumentos.get(p.clave()))
                .collect(Collectors.joining("; "));
        return "\n(Accion en curso de turnos anteriores, " + herramienta + ", con estos datos ya resueltos: " + campos
                + ". No vuelvas a consultarlos: llama a " + herramienta + " con ellos mas lo que diga la persona. Si "
                + "la persona pide otra cosa, ignora esta nota.)";
    }
}
