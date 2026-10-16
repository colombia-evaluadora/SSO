package com.co.eurekatic.aicontrol.agente.nucleo.borrador;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.esquema.NombresParametro;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.EtiquetasIds;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.Redaccion;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;
import java.util.stream.Collectors;

/**
 * La escritura que el modelo esta armando en la conversacion: la herramienta, los argumentos que ya resolvio, tal
 * como los mando, y el nombre de cada id segun la consulta de la que salio (grupo 990201 es "A"); todo con los
 * nombres de persona como seudonimos, igual que los vio el modelo.
 * Entre turnos el modelo solo conserva texto; sin esto vuelve a consultar todo y pierde lo acordado. Pura.
 *
 * @param etiquetas por clave de parametro, el nombre legible de su valor; puede faltar
 */
public record BorradorAccion(String herramienta, Map<String, Object> argumentos, Map<String, String> etiquetas) {

    public BorradorAccion {
        Objects.requireNonNull(herramienta, "herramienta");
        argumentos = Map.copyOf(argumentos);
        // Un borrador guardado antes de que existieran las etiquetas llega sin ellas.
        etiquetas = etiquetas == null ? Map.of() : Map.copyOf(etiquetas);
    }

    public BorradorAccion(String herramienta, Map<String, Object> argumentos) {
        this(herramienta, argumentos, Map.of());
    }

    /**
     * Solo los parametros de la herramienta con valor, por su clave canonica: el modelo los manda con el nombre del
     * esquema ({@code fk_tgrupo}) y lo que invento o dejo vacio no se arrastra.
     */
    public static BorradorAccion de(HerramientaDef herramienta, Map<String, Object> argumentosDelModelo) {
        NombresParametro nombres = NombresParametro.de(herramienta.parametros());
        Map<String, Object> resueltos = new LinkedHashMap<>();
        argumentosDelModelo.forEach((nombre, valor) -> {
            if (valor != null && !String.valueOf(valor).isBlank()) {
                nombres.claveCanonica(nombre).ifPresent(clave -> resueltos.put(clave, valor));
            }
        });
        return new BorradorAccion(herramienta.codigo(), resueltos);
    }

    /** Con el nombre de cada id que las consultas del turno dejaron a la vista ({@link EtiquetasIds}). */
    public BorradorAccion conEtiquetas(Map<String, String> etiquetasDeIds) {
        Map<String, String> nuevas = new LinkedHashMap<>(etiquetas);
        argumentos.forEach((clave, valor) ->
                EtiquetasIds.de(etiquetasDeIds, clave, valor).ifPresent(e -> nuevas.put(clave, e)));
        return new BorradorAccion(herramienta, argumentos, nuevas);
    }

    /**
     * El intento nuevo de la misma herramienta completa el anterior; el de otra lo reemplaza. Una etiqueta vieja
     * solo sigue si su valor no cambio.
     */
    public BorradorAccion seguidoDe(BorradorAccion nuevo) {
        if (!herramienta.equals(nuevo.herramienta)) {
            return nuevo;
        }
        Map<String, Object> juntos = new LinkedHashMap<>(argumentos);
        juntos.putAll(nuevo.argumentos);
        Map<String, String> nombres = new LinkedHashMap<>();
        etiquetas.forEach((clave, etiqueta) -> {
            if (Objects.equals(argumentos.get(clave), juntos.get(clave))) {
                nombres.put(clave, etiqueta);
            }
        });
        nombres.putAll(nuevo.etiquetas);
        return new BorradorAccion(herramienta, juntos, nombres);
    }

    /** Nota para el mensaje del turno, con la etiqueta de cada campo y el nombre de su valor; vacia si no hay nada. */
    public String nota(HerramientaDef def) {
        if (argumentos.isEmpty()) {
            return "";
        }
        NombresParametro nombres = NombresParametro.de(def.parametros());
        String campos = def.parametros().stream()
                .filter(p -> argumentos.containsKey(p.clave()))
                .map(p -> Redaccion.etiqueta(p) + " [" + nombres.nombreModelo(p.clave()) + "] = "
                        + argumentos.get(p.clave())
                        + (etiquetas.containsKey(p.clave()) ? " (" + etiquetas.get(p.clave()) + ")" : ""))
                .collect(Collectors.joining("; "));
        return "\n(Accion en curso de turnos anteriores, " + herramienta + ", con estos datos ya resueltos: " + campos
                + ". No vuelvas a consultarlos: llama a " + herramienta + " con ellos mas lo que diga la persona. Si "
                + "la persona pide otra cosa, ignora esta nota.)";
    }
}
