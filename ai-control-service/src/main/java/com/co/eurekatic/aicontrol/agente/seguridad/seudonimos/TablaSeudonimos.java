package com.co.eurekatic.aicontrol.agente.seguridad.seudonimos;

import org.springframework.ai.chat.model.ToolContext;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Seudonimos de una conversacion: cada nombre de persona que sale de la base se sustituye por un alias
 * estable ({@code Persona_7}) antes de llegar al proveedor del modelo, y se restaura en lo que ve la
 * persona. El mismo nombre recibe siempre el mismo alias en la conversacion, asi el modelo puede razonar
 * ("califica a Persona_7") sin conocer el nombre.
 *
 * <p>Solo cubre los nombres que la conversacion ya vio en un resultado; un nombre que la persona escribe
 * por primera vez llega tal cual. Segura entre hilos: las herramientas de un turno pueden correr en
 * paralelo.
 */
public final class TablaSeudonimos {

    /** Clave bajo la que la tabla viaja en el {@code ToolContext}. */
    public static final String CLAVE = "tablaSeudonimos";
    static final String PREFIJO = "Persona_";
    private static final Pattern ALIAS = Pattern.compile("(?i)\\bpersona_(\\d+)\\b");
    private static final int LONGITUD_MINIMA = 3;

    private final Map<String, String> aliasPorNombre = new ConcurrentHashMap<>();
    private final Map<String, String> nombrePorAlias = new ConcurrentHashMap<>();
    private final Map<String, String> nuevos = new ConcurrentHashMap<>();

    private TablaSeudonimos() {
    }

    public static TablaSeudonimos vacia() {
        return new TablaSeudonimos();
    }

    /** Tabla a partir de lo guardado de la conversacion: alias a nombre. */
    public static TablaSeudonimos desde(Map<String, String> nombrePorAlias) {
        TablaSeudonimos tabla = new TablaSeudonimos();
        nombrePorAlias.forEach((alias, nombre) -> {
            tabla.nombrePorAlias.put(alias, nombre);
            tabla.aliasPorNombre.put(clave(nombre), alias);
        });
        return tabla;
    }

    public static Optional<TablaSeudonimos> de(ToolContext contexto) {
        return contexto != null && contexto.getContext().get(CLAVE) instanceof TablaSeudonimos tabla
                ? Optional.of(tabla)
                : Optional.empty();
    }

    /** Alias del nombre, creandolo si es nuevo. */
    public synchronized String alias(String nombre) {
        String existente = aliasPorNombre.get(clave(nombre));
        if (existente != null) {
            return existente;
        }
        String alias = PREFIJO + (nombrePorAlias.size() + 1);
        aliasPorNombre.put(clave(nombre), alias);
        nombrePorAlias.put(alias, nombre);
        nuevos.put(alias, nombre);
        return alias;
    }

    /** Filas con los nombres de persona cambiados por su alias, tambien dentro de objetos y listas anidados. */
    public List<Map<String, Object>> ocultarFilas(List<Map<String, Object>> filas) {
        return filas.stream().map(this::ocultarMapa).toList();
    }

    /**
     * Texto con cada nombre conocido cambiado por su alias; los mas largos primero ("Ana Perez" antes que "Ana").
     * Una palabra suelta escrita toda en mayusculas no se toma por el nombre de una sola palabra: en el esquema
     * los codigos y roles van asi, y un apellido "Docente" convertiria el rol DOCENTE en una persona.
     */
    public String ocultar(String texto) {
        String resultado = texto;
        List<Map.Entry<String, String>> porLongitud = new ArrayList<>(nombrePorAlias.entrySet());
        porLongitud.sort(Comparator.comparingInt((Map.Entry<String, String> e) -> e.getValue().length()).reversed());
        for (Map.Entry<String, String> entrada : porLongitud) {
            String nombre = entrada.getValue();
            if (nombre.length() >= LONGITUD_MINIMA) {
                boolean respetaCodigos = !nombre.strip().contains(" ") && !esMayusculas(nombre);
                resultado = Pattern.compile("(?iu)(?<!\\p{L})" + Pattern.quote(nombre) + "(?!\\p{L})")
                        .matcher(resultado).replaceAll(m -> Matcher.quoteReplacement(
                                respetaCodigos && esMayusculas(m.group()) ? m.group() : entrada.getKey()));
            }
        }
        return resultado;
    }

    private static boolean esMayusculas(String texto) {
        return texto.chars().anyMatch(Character::isLetter) && texto.equals(texto.toUpperCase(Locale.ROOT));
    }

    /** Texto con cada alias cambiado por el nombre real; un alias desconocido se deja como esta. */
    public String revelar(String texto) {
        return ALIAS.matcher(texto).replaceAll(m -> Matcher.quoteReplacement(
                nombrePorAlias.getOrDefault(PREFIJO + m.group(1), m.group())));
    }

    /** Valor de un argumento del modelo con los alias resueltos, tambien dentro de listas y objetos. */
    public Object revelarValor(Object valor) {
        return switch (valor) {
            case String texto -> revelar(texto);
            case List<?> lista -> lista.stream().map(this::revelarValor).toList();
            case Map<?, ?> mapa -> {
                Map<Object, Object> copia = new LinkedHashMap<>();
                mapa.forEach((k, v) -> copia.put(k, v == null ? null : revelarValor(v)));
                yield copia;
            }
            case null, default -> valor;
        };
    }

    /** Alias creados en este turno, para guardarlos con la conversacion. */
    public Map<String, String> nuevos() {
        return Map.copyOf(nuevos);
    }

    private Map<String, Object> ocultarMapa(Map<?, ?> fila) {
        Map<String, Object> copia = new LinkedHashMap<>();
        fila.forEach((k, v) -> {
            String columna = String.valueOf(k);
            copia.put(columna, ocultarValor(columna, v));
        });
        return copia;
    }

    private Object ocultarValor(String columna, Object valor) {
        return switch (valor) {
            case String texto when CamposDePersona.esNombreDePersona(columna) && !texto.isBlank() -> alias(texto.strip());
            case Map<?, ?> mapa -> ocultarMapa(mapa);
            case List<?> lista -> lista.stream().map(e -> ocultarValor(columna, e)).toList();
            case null, default -> valor;
        };
    }

    private static String clave(String nombre) {
        return nombre.strip().toLowerCase(Locale.ROOT);
    }
}
