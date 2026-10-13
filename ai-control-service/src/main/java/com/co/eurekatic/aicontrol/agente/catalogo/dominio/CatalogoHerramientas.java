package com.co.eurekatic.aicontrol.agente.catalogo.dominio;

import java.util.Collection;
import java.util.Collections;
import java.util.EnumMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.TreeMap;

/**
 * Catalogo de herramientas ya validadas, en memoria e inmutable. Se reemplaza entero
 * al refrescar; nunca se modifica en sitio.
 */
public final class CatalogoHerramientas {

    private static final CatalogoHerramientas VACIO = new CatalogoHerramientas(List.of());

    /** Ordenado por codigo, para que el modelo vea siempre el mismo orden. */
    private final Map<String, HerramientaDef> porCodigo;
    private final Map<TipoHerramienta, List<HerramientaDef>> porTipo;

    private CatalogoHerramientas(Collection<HerramientaDef> herramientas) {
        TreeMap<String, HerramientaDef> ordenadas = new TreeMap<>();
        for (HerramientaDef herramienta : herramientas) {
            if (ordenadas.putIfAbsent(herramienta.codigo(), herramienta) != null) {
                throw new IllegalArgumentException("codigo de herramienta duplicado: " + herramienta.codigo());
            }
        }
        this.porCodigo = Collections.unmodifiableMap(ordenadas);

        EnumMap<TipoHerramienta, List<HerramientaDef>> tipos = new EnumMap<>(TipoHerramienta.class);
        for (TipoHerramienta tipo : TipoHerramienta.values()) {
            tipos.put(tipo, ordenadas.values().stream().filter(h -> h.tipo() == tipo).toList());
        }
        this.porTipo = Collections.unmodifiableMap(tipos);
    }

    public static CatalogoHerramientas vacio() {
        return VACIO;
    }

    /** @throws IllegalArgumentException si dos herramientas comparten codigo */
    public static CatalogoHerramientas con(Collection<HerramientaDef> herramientas) {
        return new CatalogoHerramientas(herramientas);
    }

    public Optional<HerramientaDef> buscar(String codigo) {
        return Optional.ofNullable(porCodigo.get(codigo));
    }

    /** Todas las herramientas, ordenadas por codigo. */
    public List<HerramientaDef> todas() {
        return List.copyOf(porCodigo.values());
    }

    /** Las herramientas de un tipo, ordenadas por codigo. */
    public List<HerramientaDef> porTipo(TipoHerramienta tipo) {
        return porTipo.get(tipo);
    }

    public boolean estaVacio() {
        return porCodigo.isEmpty();
    }

    public int tamano() {
        return porCodigo.size();
    }
}
