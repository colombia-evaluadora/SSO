package com.co.eurekatic.aicontrol.agente.ui.acciones;

import com.co.eurekatic.aicontrol.agente.seguridad.NormalizadorTexto;
import tools.jackson.core.JacksonException;
import tools.jackson.core.type.TypeReference;
import tools.jackson.databind.json.JsonMapper;

import java.util.Collection;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Lo que la base dice de un formulario gestionado por ella: que secciones estan ocultas. La configuracion
 * de las funciones de campos disponibles (p. ej. {@code {recuperacion:{visible:false, ...}}}) se recorre
 * entera y toda clave cuyo valor tenga {@code visible:false} oculta los campos cuyo nombre la contiene
 * ({@code recuperacion} oculta {@code recuperacionFecha}). Pura.
 */
public final class ConfiguracionCamposDb {

    private static final ConfiguracionCamposDb SIN_RESTRICCIONES = new ConfiguracionCamposDb(Set.of());
    private static final JsonMapper JSON = JsonMapper.builder().build();
    private static final TypeReference<Map<String, Object>> MAPA = new TypeReference<>() {
    };
    private static final int PROFUNDIDAD_MAXIMA = 6;
    private static final String VISIBLE = "visible";

    private final Set<String> ocultas;

    private ConfiguracionCamposDb(Set<String> ocultas) {
        this.ocultas = Set.copyOf(ocultas);
    }

    /** Formulario de alta: aun no hay registro del que leer configuracion; decide el gate al enviar. */
    public static ConfiguracionCamposDb sinRestricciones() {
        return SIN_RESTRICCIONES;
    }

    /** A partir de las filas que devuelve la herramienta de configuracion. */
    public static ConfiguracionCamposDb desde(List<Map<String, Object>> filas) {
        Set<String> ocultas = new HashSet<>();
        filas.forEach(fila -> recorrer(fila, ocultas, 0));
        return new ConfiguracionCamposDb(ocultas);
    }

    public boolean oculta(String campo) {
        String nombre = clave(campo);
        return ocultas.stream().anyMatch(nombre::contains);
    }

    Set<String> ocultas() {
        return ocultas;
    }

    private static void recorrer(Object nodo, Set<String> ocultas, int profundidad) {
        if (profundidad > PROFUNDIDAD_MAXIMA) {
            return;
        }
        switch (nodo) {
            case Map<?, ?> mapa -> mapa.forEach((k, v) -> {
                if (k instanceof String nombre && esOculto(v)) {
                    ocultas.add(clave(nombre));
                }
                recorrer(v, ocultas, profundidad + 1);
            });
            case Collection<?> lista -> lista.forEach(e -> recorrer(e, ocultas, profundidad + 1));
            case String texto when texto.strip().startsWith("{") -> leerJson(texto)
                    .forEach(m -> recorrer(m, ocultas, profundidad + 1));
            case null, default -> {
            }
        }
    }

    private static boolean esOculto(Object valor) {
        return valor instanceof Map<?, ?> mapa
                && (Boolean.FALSE.equals(mapa.get(VISIBLE)) || "false".equals(mapa.get(VISIBLE)));
    }

    /** Las columnas jsonb pueden llegar como texto JSON. */
    private static List<Map<String, Object>> leerJson(String texto) {
        try {
            return List.of(JSON.readValue(texto, MAPA));
        } catch (JacksonException e) {
            return List.of();
        }
    }

    /** Sin tildes, mayusculas ni separadores: {@code fecha_recuperacion} y {@code fechaRecuperacion} comparan igual. */
    private static String clave(String texto) {
        return NormalizadorTexto.plegar(texto).replaceAll("[^\\p{L}\\p{N}]", "");
    }
}
