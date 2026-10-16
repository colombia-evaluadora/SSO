package com.co.eurekatic.aicontrol.agente.ui.pantallas;

import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.AccionUi;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.ui.UiFixture;
import com.co.eurekatic.aicontrol.agente.ui.registro.Pantalla;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class BuscadorPantallasTest {

    private static final List<Pantalla> VISIBLES = UiFixture.REGISTRO.pantallasVisibles(UiFixture.MENUS_DOCENTE);

    @Test
    void encuentraPorSinonimoSinTildesNiPlurales() {
        assertThat(BuscadorPantallas.buscar("¿Dónde edito a los PROFESORES?", VISIBLES, 3))
                .first().isEqualTo(UiFixture.FUNCIONARIOS);
        assertThat(BuscadorPantallas.buscar("quiero calificar actividades", VISIBLES, 3))
                .first().isEqualTo(UiFixture.PLANEADOR);
    }

    @Test
    void nuncaDevuelveUnaPantallaQueElUsuarioNoVe() {
        assertThat(VISIBLES).doesNotContain(UiFixture.ROLES);
        assertThat(BuscadorPantallas.buscar("donde cambio los permisos y roles", VISIBLES, 3)).isEmpty();
    }

    @Test
    void lasPalabrasVaciasNoBuscanNada() {
        assertThat(BuscadorPantallas.raices("¿dónde está la pantalla para ver?")).isEmpty();
        assertThat(BuscadorPantallas.buscar("donde esta", VISIBLES, 3)).isEmpty();
    }

    @Test
    void laRespuestaLlevaMigasYUnEnlaceDeNavegacion() {
        RespuestaAgente.Ui respuesta = BuscarPantallaHerramienta.respuesta(List.of(UiFixture.PLANEADOR, UiFixture.FUNCIONARIOS));

        assertThat(respuesta.texto()).startsWith("Lo encuentras en Gestión Académica › Planeador.")
                .contains("Establecimiento Educativo › Funcionarios");
        assertThat(respuesta.acciones()).containsExactly(
                new AccionUi.Navegar("planeador", "/app/planeador/actividades", Map.of()));
    }
}
