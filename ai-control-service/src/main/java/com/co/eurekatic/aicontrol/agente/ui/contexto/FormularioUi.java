package com.co.eurekatic.aicontrol.agente.ui.contexto;

import java.util.List;
import java.util.Objects;
import java.util.Optional;

/**
 * Formulario abierto en la pantalla, tal como lo describe el front.
 *
 * @param codigo   codigo del formulario en {@code ai.ui_formulario}
 * @param entidad  id del registro que el formulario edita; cadena vacia si es de alta
 * @param campos   campos que el front declara
 */
public record FormularioUi(String codigo, String entidad, List<CampoUi> campos) {

    public FormularioUi {
        Objects.requireNonNull(codigo, "codigo");
        Objects.requireNonNull(entidad, "entidad");
        campos = List.copyOf(campos);
    }

    public Optional<CampoUi> campo(String nombre) {
        return campos.stream().filter(c -> c.nombre().equals(nombre)).findFirst();
    }

    public Optional<String> entidadId() {
        return entidad.isBlank() ? Optional.empty() : Optional.of(entidad);
    }
}
