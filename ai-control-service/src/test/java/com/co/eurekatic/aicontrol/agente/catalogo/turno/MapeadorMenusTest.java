package com.co.eurekatic.aicontrol.agente.catalogo.turno;

import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class MapeadorMenusTest {

    @Test
    void soloLecturaSiNoPuedeCrearNiEditar() {
        var r = MapeadorMenus.desde(List.of(
                new FilaMenu("FUNCIONARIOS", true, false, false, false),
                new FilaMenu("PLANEADOR", true, false, true, false),
                new FilaMenu("CREAR", true, true, false, false)));

        assertThat(r).containsEntry("FUNCIONARIOS", new AccesoMenu(true))
                .containsEntry("PLANEADOR", new AccesoMenu(false))
                .containsEntry("CREAR", new AccesoMenu(false));
    }

    @Test
    void eliminarSinCrearNiEditarSigueSiendoSoloLectura() {
        var r = MapeadorMenus.desde(List.of(new FilaMenu("X", true, false, false, true)));

        assertThat(r).containsEntry("X", new AccesoMenu(true));
    }

    @Test
    void unMenuNoVisibleOSinCodigoSeOmite() {
        var r = MapeadorMenus.desde(List.of(
                new FilaMenu("OCULTO", false, true, true, true),
                new FilaMenu("  ", true, false, false, false),
                new FilaMenu(null, true, false, false, false)));

        assertThat(r).isEmpty();
    }
}
