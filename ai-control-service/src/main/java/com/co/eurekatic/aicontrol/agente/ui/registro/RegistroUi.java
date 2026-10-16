package com.co.eurekatic.aicontrol.agente.ui.registro;

import com.co.eurekatic.aicontrol.agente.catalogo.turno.AccesoMenu;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.function.Function;
import java.util.stream.Collectors;

/** Pantallas y formularios registrados para la UI asistida. Inmutable: se reemplaza entero al refrescar. */
public final class RegistroUi {

    private static final RegistroUi VACIO = new RegistroUi(List.of(), List.of());

    private final List<Pantalla> pantallas;
    private final Map<String, FormularioRegistrado> formularios;

    private RegistroUi(List<Pantalla> pantallas, List<FormularioRegistrado> formularios) {
        this.pantallas = List.copyOf(pantallas);
        this.formularios = formularios.stream()
                .collect(Collectors.toUnmodifiableMap(FormularioRegistrado::codigo, Function.identity(), (a, b) -> a));
    }

    public static RegistroUi con(List<Pantalla> pantallas, List<FormularioRegistrado> formularios) {
        return new RegistroUi(pantallas, formularios);
    }

    public static RegistroUi vacio() {
        return VACIO;
    }

    public boolean estaVacio() {
        return pantallas.isEmpty() && formularios.isEmpty();
    }

    /** Solo las pantallas de menus que el usuario ve: el agente nunca indica una sin acceso. */
    public List<Pantalla> pantallasVisibles(Map<String, AccesoMenu> menus) {
        return pantallas.stream().filter(p -> menus.containsKey(p.menuCodigo())).toList();
    }

    /** Formularios registrados de menus que el usuario ve. */
    public List<FormularioRegistrado> formulariosVisibles(Map<String, AccesoMenu> menus) {
        return formularios.values().stream().filter(f -> menus.containsKey(f.menuCodigo())).toList();
    }

    public Optional<FormularioRegistrado> formulario(String codigo) {
        return Optional.ofNullable(formularios.get(codigo));
    }

    public int pantallasCargadas() {
        return pantallas.size();
    }
}
