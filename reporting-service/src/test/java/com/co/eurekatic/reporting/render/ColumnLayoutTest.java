package com.co.eurekatic.reporting.render;

import com.co.eurekatic.reporting.config.ReportingProperties;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * `resolver` con `columnasPedidas` es lo que le permite al front exportar
 * solo las columnas que tiene visibles en la tabla, en vez del set fijo del
 * YAML -- estos tests son la garantia de que ese filtro nunca deja pasar una
 * clave que no estuviera ya declarada para el reporte.
 */
class ColumnLayoutTest {

    private static ReportingProperties.Report definicion() {
        ReportingProperties.Report def = new ReportingProperties.Report();
        Map<String, String> cols = new LinkedHashMap<>();
        cols.put("documento", "Documento");
        cols.put("nombre", "Nombre");
        cols.put("estado", "Estado");
        def.setColumns(cols);
        return def;
    }

    @Test
    void sinColumnasPedidasDevuelveTodasLasConfiguradas() {
        Map<String, String> resultado = ColumnLayout.resolver(definicion(), List.of(), null);
        assertEquals(List.of("documento", "nombre", "estado"), List.copyOf(resultado.keySet()));
    }

    @Test
    void filtraYReordenaSegunLoPedido() {
        // Pedidas en un orden distinto al configurado -- el resultado
        // respeta el orden de columnasPedidas (el orden visible de la tabla
        // del front), no el del YAML.
        Map<String, String> resultado =
                ColumnLayout.resolver(definicion(), List.of(), List.of("estado", "documento"));
        assertEquals(List.of("estado", "documento"), List.copyOf(resultado.keySet()));
        assertEquals("Estado", resultado.get("estado"));
    }

    @Test
    void ignoraClavesQueNoEstenDeclaradas() {
        // "id_interno" no esta en el catalogo del reporte: pedirla no la
        // agrega -- columnasPedidas filtra el catalogo, no lo amplia.
        Map<String, String> resultado =
                ColumnLayout.resolver(definicion(), List.of(), List.of("nombre", "id_interno"));
        assertEquals(List.of("nombre"), List.copyOf(resultado.keySet()));
    }

    @Test
    void siNingunaClavePedidaEsConocidaCaeAlCatalogoCompleto() {
        // Todas desconocidas: un reporte en blanco es peor que uno con mas
        // columnas de las esperadas, asi que se cae al set completo.
        Map<String, String> resultado =
                ColumnLayout.resolver(definicion(), List.of(), List.of("a", "b"));
        assertEquals(List.of("documento", "nombre", "estado"), List.copyOf(resultado.keySet()));
    }

    @Test
    void columnasPedidasVaciaEsIgualQueNull() {
        Map<String, String> resultado = ColumnLayout.resolver(definicion(), List.of(), List.of());
        assertEquals(List.of("documento", "nombre", "estado"), List.copyOf(resultado.keySet()));
    }
}
