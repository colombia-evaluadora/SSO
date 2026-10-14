package com.co.eurekatic.reporting.config;

import org.junit.jupiter.api.Test;

import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;

/**
 * `conEtiquetas` deja que el front cambie encabezados (los rotulos del
 * planeador) sin abrir un camino para agregar columnas ni para tocar la
 * configuracion compartida entre pedidos.
 */
class ReportEtiquetasTest {

    private static ReportingProperties.Report definicion() {
        ReportingProperties.Report def = new ReportingProperties.Report();
        Map<String, String> cols = new LinkedHashMap<>();
        cols.put("titulo", "Actividad");
        cols.put("unidad", "Unidad tematica");
        cols.put("estado", "Estado");
        def.setColumns(cols);
        def.setTitle("Actividades del planeador");
        return def;
    }

    @Test
    void renombraSoloLasColumnasDeclaradasYConservaElOrden() {
        ReportingProperties.Report def = definicion();
        ReportingProperties.Report vista = def.conEtiquetas(Map.of(
                "unidad", "Proyecto pedagógico",
                "titulo", "Experiencia",
                "id_interno", "No debe salir"));

        assertEquals(List.of("titulo", "unidad", "estado"), List.copyOf(vista.getColumns().keySet()));
        assertEquals("Experiencia", vista.getColumns().get("titulo"));
        assertEquals("Proyecto pedagógico", vista.getColumns().get("unidad"));
        assertEquals("Estado", vista.getColumns().get("estado"));
        assertEquals("Actividades del planeador", vista.getTitle());
    }

    @Test
    void noModificaLaDefinicionCompartida() {
        ReportingProperties.Report def = definicion();
        def.conEtiquetas(Map.of("titulo", "Experiencia"));
        assertEquals("Actividad", def.getColumns().get("titulo"));
    }

    @Test
    void sinEtiquetasAplicablesDevuelveLaMismaInstancia() {
        ReportingProperties.Report def = definicion();
        Map<String, String> enBlanco = new HashMap<>();
        enBlanco.put("titulo", "   ");
        enBlanco.put("unidad", null);
        assertSame(def, def.conEtiquetas(null));
        assertSame(def, def.conEtiquetas(Map.of()));
        assertSame(def, def.conEtiquetas(enBlanco));
        assertSame(def, def.conEtiquetas(Map.of("desconocida", "X")));
    }

    @Test
    void recortaUnEncabezadoDemasiadoLargo() {
        String largo = "x".repeat(ReportingProperties.Report.MAX_ETIQUETA + 20);
        ReportingProperties.Report vista = definicion().conEtiquetas(Map.of("titulo", largo));
        assertEquals(ReportingProperties.Report.MAX_ETIQUETA, vista.getColumns().get("titulo").length());
    }
}
