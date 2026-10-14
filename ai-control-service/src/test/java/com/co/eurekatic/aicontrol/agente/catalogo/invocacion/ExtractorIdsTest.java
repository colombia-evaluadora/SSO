package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class ExtractorIdsTest {

    @Test
    void extraeSoloLasColumnasQueParecenIds() {
        List<Map<String, Object>> filas = List.of(
                Map.of("id", 7, "nombre", "Ana", "pk_tsede", 3L, "fk_tgrupo", 9, "idParent", 1, "fk_x_id", 4));

        assertThat(ExtractorIds.extraer(filas)).containsExactlyInAnyOrder("7", "3", "9", "1", "4");
    }

    @Test
    void extraeLosIdsDeUnListadoPaginadoAnidado() {
        // Forma de POST /establecimientos/funcionarios/query: la pagina va dentro de la unica fila.
        List<Map<String, Object>> filas = List.of(Map.of("rows", List.of(
                Map.of("pk_empleado", 990610, "primer_nombre", "x",
                        "roles", List.of(Map.of("id", 14, "nombre", "DOCENTE")))),
                "total_count", 1));

        assertThat(ExtractorIds.extraer(filas)).containsExactlyInAnyOrder("990610", "14");
    }

    @Test
    void unEnteroLlegadoComoDecimalSeCanonicalizaComoEntero() {
        assertThat(ExtractorIds.textoDe(12.0)).isEqualTo("12");
        assertThat(ExtractorIds.textoDe(12.5)).isNull();
        assertThat(ExtractorIds.textoDe(Double.NaN)).isNull();
        assertThat(ExtractorIds.textoDe(" 33 ")).isEqualTo("33");
        assertThat(ExtractorIds.textoDe("  ")).isNull();
    }

    @Test
    void elRegistroSeLimitaPorResultado() {
        List<Map<String, Object>> filas = new java.util.ArrayList<>();
        for (int i = 0; i < ExtractorIds.MAX_POR_RESULTADO + 50; i++) {
            filas.add(Map.of("id", i));
        }

        assertThat(ExtractorIds.extraer(filas)).hasSize(ExtractorIds.MAX_POR_RESULTADO);
    }
}
