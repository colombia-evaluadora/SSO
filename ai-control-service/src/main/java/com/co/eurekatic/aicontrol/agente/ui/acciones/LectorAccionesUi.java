package com.co.eurekatic.aicontrol.agente.ui.acciones;

import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.AccionUi;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * Convierte las acciones que propone el modelo ({@code [{op, ...}]}) en {@link AccionUi}. Solo comprueba
 * la forma; los permisos y el contenido los decide {@link ValidadorAccionesUi}. La URL de NAVEGAR queda
 * vacia: la pone el validador desde el registro, nunca el modelo.
 */
public final class LectorAccionesUi {

    static final int MAX_ACCIONES = 10;

    private LectorAccionesUi() {
    }

    /** Acciones con forma valida y, aparte, un error legible para el modelo por cada una que no la tiene. */
    public record Lectura(List<AccionUi> acciones, List<String> errores) {
        public Lectura {
            acciones = List.copyOf(acciones);
            errores = List.copyOf(errores);
        }
    }

    public static Lectura leer(Object crudo) {
        return leer(crudo, Optional.empty());
    }

    /**
     * @param formularioUnico el formulario abierto si es el unico: una accion sobre un formulario que no lo
     *                        nombra se entiende sobre el. Con varios abiertos, tiene que nombrarlo.
     */
    public static Lectura leer(Object crudo, Optional<String> formularioUnico) {
        List<AccionUi> acciones = new ArrayList<>();
        List<String> errores = new ArrayList<>();
        if (!(crudo instanceof List<?> lista) || lista.isEmpty()) {
            return new Lectura(List.of(), List.of("Indica al menos una accion en 'acciones'."));
        }
        lista.stream().limit(MAX_ACCIONES).forEach(elemento -> accion(elemento, formularioUnico)
                .ifPresentOrElse(acciones::add,
                        () -> errores.add("Accion con forma no valida: " + describir(elemento) + ".")));
        return new Lectura(acciones, errores);
    }

    private static Optional<AccionUi> accion(Object crudo, Optional<String> formularioUnico) {
        if (!(crudo instanceof Map<?, ?> m) || !(m.get("op") instanceof String op)) {
            return Optional.empty();
        }
        Optional<String> formulario = texto(m, "formulario").or(() -> formularioUnico);
        return switch (op) {
            case "NAVEGAR" -> texto(m, "pantalla").map(p -> new AccionUi.Navegar(p, "", textos(m.get("params"))));
            case "RELLENAR" -> formulario.map(f -> new AccionUi.Rellenar(f, valores(m.get("valores"))));
            case "LIMPIAR_CAMPO" -> formulario.flatMap(f -> texto(m, "campo").map(c -> new AccionUi.LimpiarCampo(f, c)));
            case "RESALTAR" -> formulario.flatMap(f -> texto(m, "campo").map(c -> new AccionUi.Resaltar(f, c)));
            case "ABRIR_PESTANA" -> texto(m, "pestana").map(AccionUi.AbrirPestana::new);
            case "APLICAR_FILTROS" -> Optional.of(new AccionUi.AplicarFiltros(valores(m.get("filtros"))));
            default -> Optional.empty();
        };
    }

    private static Optional<String> texto(Map<?, ?> m, String clave) {
        return m.get(clave) instanceof String s && !s.isBlank() ? Optional.of(s.strip()) : Optional.empty();
    }

    /** Solo escalares, sin nulos: un objeto anidado no es un valor de campo. */
    private static Map<String, Object> valores(Object crudo) {
        Map<String, Object> limpio = new LinkedHashMap<>();
        if (crudo instanceof Map<?, ?> m) {
            m.forEach((k, v) -> {
                if (k instanceof String clave && (v instanceof String || v instanceof Number || v instanceof Boolean)) {
                    limpio.put(clave, v);
                }
            });
        }
        return limpio;
    }

    private static Map<String, String> textos(Object crudo) {
        Map<String, String> limpio = new LinkedHashMap<>();
        valores(crudo).forEach((k, v) -> limpio.put(k, String.valueOf(v)));
        return limpio;
    }

    /** La op y las claves que llegaron (nunca los valores), para que el modelo vea que falto. */
    private static String describir(Object crudo) {
        if (!(crudo instanceof Map<?, ?> m)) {
            return "no es un objeto";
        }
        String op = m.get("op") instanceof String s ? s : "sin op";
        return op + " con claves " + m.keySet();
    }
}
