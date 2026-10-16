package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class EtiquetasHerramientasTest {

    @Test
    void lasDeControlTienenEtiquetaPropiaYElRestoSeArmaConElCodigo() {
        assertThat(EtiquetasHerramientas.de("buscar_pantalla")).isEqualTo("Buscando la pantalla");
        assertThat(EtiquetasHerramientas.de("sedes_listar")).isEqualTo("Consultando sedes");
        assertThat(EtiquetasHerramientas.de("funcionario_detalle")).isEqualTo("Consultando el detalle de funcionario");
        assertThat(EtiquetasHerramientas.de("crear_actividad_planeador")).isEqualTo("Preparando: crear actividad planeador");
        assertThat(EtiquetasHerramientas.de("actividades_mias_listar")).isEqualTo("Consultando actividades mias");
    }
}
