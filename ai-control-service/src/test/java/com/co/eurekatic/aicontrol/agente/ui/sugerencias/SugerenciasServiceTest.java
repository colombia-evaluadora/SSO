package com.co.eurekatic.aicontrol.agente.ui.sugerencias;

import com.co.eurekatic.aicontrol.agente.ui.UiFixture;
import com.co.eurekatic.aicontrol.agente.ui.registro.Pantalla;
import com.co.eurekatic.aicontrol.agente.ui.sugerencias.CatalogoSugerencias.Sugerencia;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

class SugerenciasServiceTest {

    private static final List<Pantalla> VISIBLES = List.of(UiFixture.FUNCIONARIOS, UiFixture.PLANEADOR);

    @Test
    void reconoceLaPantallaPorElPrefijoDeLaRutaSinQuery() {
        assertThat(SugerenciasService.pantallaDe("/app/planeador/actividades?dia=2026-10-16", VISIBLES))
                .contains(UiFixture.PLANEADOR);
        assertThat(SugerenciasService.pantallaDe("/app/establecimiento-educativo/funcionarios/editar/3", VISIBLES))
                .contains(UiFixture.FUNCIONARIOS);
        assertThat(SugerenciasService.pantallaDe("/app/planeador/actividades-x", VISIBLES)).isEmpty();
        assertThat(SugerenciasService.pantallaDe("", VISIBLES)).isEmpty();
    }

    @Test
    void sinHerramientasSoloOfreceAyudaYNavegacionSiVePantallas() {
        SugerenciasService.Capacidades sinDatos = new SugerenciasService.Capacidades(false, false, false, true, false,
                List.of());

        List<Sugerencia> sugerencias = SugerenciasService.sugerencias(Optional.of(UiFixture.PLANEADOR), List.of(),
                sinDatos);

        assertThat(sugerencias).isNotEmpty()
                .allMatch(s -> s.menuCodigo().isEmpty())
                .extracting(Sugerencia::tipo)
                .containsOnly(CatalogoSugerencias.Tipo.AYUDA, CatalogoSugerencias.Tipo.NAVEGACION);
    }
}
