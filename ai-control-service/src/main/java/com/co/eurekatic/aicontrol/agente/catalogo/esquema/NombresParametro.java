package com.co.eurekatic.aicontrol.agente.catalogo.esquema;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.ParametroDef;

import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

/**
 * Mapeo bidireccional entre la clave canonica del query-service y el nombre legible que ve
 * el modelo: {@code PARAM.ID} se expone como {@code id}, {@code BODY.PERSON.EMAIL} como
 * {@code person_email}. Si dos claves dan el mismo nombre corto, las dos usan el nombre
 * completo ({@code param_id}, {@code body_id}); si aun asi chocan, no hay herramienta.
 */
public final class NombresParametro {

    private final Map<String, String> porClave;
    private final Map<String, String> porNombre;

    private NombresParametro(Map<String, String> porClave) {
        this.porClave = Map.copyOf(porClave);
        Map<String, String> inversa = new HashMap<>();
        porClave.forEach((clave, nombre) -> inversa.put(nombre, clave));
        this.porNombre = Map.copyOf(inversa);
    }

    /**
     * @throws IllegalArgumentException si dos parametros no pueden tener nombres distintos
     */
    public static NombresParametro de(Iterable<ParametroDef> parametros) {
        Map<String, String> porClave = new LinkedHashMap<>();
        Set<String> usados = new HashSet<>();
        Map<String, Integer> repeticiones = new HashMap<>();
        for (ParametroDef parametro : parametros) {
            repeticiones.merge(nombreCorto(parametro.clave()), 1, Integer::sum);
        }
        for (ParametroDef parametro : parametros) {
            String corto = nombreCorto(parametro.clave());
            String nombre = repeticiones.get(corto) > 1 ? nombreCompleto(parametro.clave()) : corto;
            if (!usados.add(nombre)) {
                throw new IllegalArgumentException("nombres de parametro en colision: " + parametro.clave());
            }
            porClave.put(parametro.clave(), nombre);
        }
        return new NombresParametro(porClave);
    }

    /** Nombre que ve el modelo para una clave canonica. */
    public String nombreModelo(String clave) {
        String nombre = porClave.get(clave);
        if (nombre == null) {
            throw new IllegalArgumentException("clave fuera del esquema: " + clave);
        }
        return nombre;
    }

    /** Clave canonica de un nombre que mando el modelo; vacio si no existe. */
    public Optional<String> claveCanonica(String nombreModelo) {
        return Optional.ofNullable(porNombre.get(nombreModelo));
    }

    /** Nombres legibles de todos los parametros. */
    public Set<String> nombres() {
        return porNombre.keySet();
    }

    private static String nombreCorto(String clave) {
        return clave.substring(clave.indexOf('.') + 1).toLowerCase(Locale.ROOT).replace('.', '_');
    }

    private static String nombreCompleto(String clave) {
        return clave.toLowerCase(Locale.ROOT).replace('.', '_');
    }
}
