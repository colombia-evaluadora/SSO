package com.co.eurekatic.aicontrol.observaciones;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class ResumenRendererTest {

    @Test
    void rendersParrafosYListasEnTextoPlano() {
        var r = new ResumenEstructurado(
                "[ESTUDIANTE] tuvo un periodo de avances.",
                List.of(new ResumenEstructurado.Dimension("Comunicativa", "Expresa ideas con claridad."),
                        new ResumenEstructurado.Dimension("Corporal", "  ")),
                List.of("Curiosidad.", "Trabajo en equipo"),
                List.of(),
                List.of("Leer cuentos en casa"),
                "Felicitaciones.");

        assertThat(ResumenRenderer.render(r)).isEqualTo("""
                [ESTUDIANTE] tuvo un periodo de avances.

                Dimensión Comunicativa: Expresa ideas con claridad.

                Fortalezas: Curiosidad; Trabajo en equipo.

                Recomendaciones para el hogar: Leer cuentos en casa.

                Felicitaciones.""");
    }

    @Test
    void toleraCamposNulos() {
        assertThat(ResumenRenderer.render(new ResumenEstructurado(null, null, null, null, null, "Cierre.")))
                .isEqualTo("Cierre.");
    }

    @Test
    void serializaSinElNombreDelEstudiante() {
        Fuentes f = Fuentes.desdeFilas(TipoResumen.PERIODO, List.of(
                Map.of("fecha", "2026-08-31T00:00:00.000Z", "actividad", "Cuento", "asignatura", "Dimension comunicativa",
                        "observacion", "Sofia narra el cuento", "estudiante", "Sofia")));

        String material = GeneradorResumen.serializar(TipoResumen.PERIODO, f);

        assertThat(material)
                .isEqualTo("- 2026-08-31 | Actividad: Cuento | Asignatura: Dimension comunicativa | Observación: [ESTUDIANTE] narra el cuento")
                .doesNotContain("Sofia");
    }

    @Test
    void detectaTextoModificadoPorElDocente() {
        Fuentes f = Fuentes.desdeFilas(TipoResumen.ANIO, List.of(
                Map.of("periodo", "P1", "observacion", "x", "ESTADO_GUARDADO", "MODIFICADA")));
        assertThat(f.modificadaPorDocente()).isTrue();
        assertThat(f.piezas().getFirst().etiqueta()).isEqualTo("P1");
    }
}
