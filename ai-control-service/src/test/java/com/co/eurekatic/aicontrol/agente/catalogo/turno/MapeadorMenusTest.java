package com.co.eurekatic.aicontrol.agente.catalogo.turno;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class MapeadorMenusTest {

    @Test
    void soloCuentaComoSoloLecturaLoQueNoPuedeModificar() {
        Map<String, AccesoMenu> r = MapeadorMenus.desde(List.of(
                Map.of("codigo", "FUNCIONARIOS", "puede_ver", true, "puede_crear", false,
                        "puede_editar", false, "puede_eliminar", false),
                Map.of("codigo", "PLANEADOR", "puede_ver", true, "puede_crear", false,
                        "puede_editar", true, "puede_eliminar", false)));

        assertThat(r).containsEntry("FUNCIONARIOS", new AccesoMenu(true))
                .containsEntry("PLANEADOR", new AccesoMenu(false));
    }

    @Test
    void unMenuNoVisibleOSinCodigoSeOmite() {
        Map<String, AccesoMenu> r = MapeadorMenus.desde(List.of(
                Map.of("codigo", "OCULTO", "puede_ver", false),
                Map.of("puede_ver", true),
                Map.of("codigo", "  ", "puede_ver", true)));

        assertThat(r).isEmpty();
    }
}
