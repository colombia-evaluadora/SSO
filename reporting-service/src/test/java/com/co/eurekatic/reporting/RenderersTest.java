package com.co.eurekatic.reporting;

import com.co.eurekatic.reporting.config.ReportingProperties;
import com.co.eurekatic.reporting.render.ExcelRenderer;
import com.co.eurekatic.reporting.render.PdfRenderer;
import com.co.eurekatic.reporting.render.ReportMeta;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Ejercita los dos renderizadores de verdad — compila el diseno, lo
 * llena y exporta — sin necesitar token ni query-service.
 *
 * <p>Es la parte que mas facil se rompe en silencio: un cambio de API de
 * Jasper o una fuente ausente no dan error de compilacion, dan un
 * archivo corrupto en produccion.
 */
class RenderersTest {

    /** Filas con la misma forma que devuelve fn_usu_empleados_listar,
     *  incluidas las columnas agregadas que llegan como JSON. */
    private static List<Map<String, Object>> filas() {
        Map<String, Object> a = new LinkedHashMap<>();
        a.put("numero_documento", "1010101");
        a.put("nombre_completo", "María Peña Gómez");   // tildes y ñ
        a.put("estado_label", "Activo");
        a.put("jornada_nombre", "Mañana");
        a.put("roles", List.of(Map.of("nombre", "Rector"), Map.of("nombre", "Docente")));
        a.put("sedes", List.of("Sede Principal"));

        Map<String, Object> b = new LinkedHashMap<>();
        b.put("numero_documento", "2020202");
        b.put("nombre_completo", "Juan Ríos");
        b.put("estado_label", null);                     // nulo
        b.put("jornada_nombre", "Tarde");
        b.put("roles", List.of());
        b.put("sedes", null);

        return List.of(a, b);
    }

    private static ReportingProperties.Report definicion() {
        ReportingProperties.Report def = new ReportingProperties.Report();
        def.setTitle("Funcionarios");
        def.setFileName("funcionarios");
        Map<String, String> cols = new LinkedHashMap<>();
        cols.put("numero_documento", "Documento");
        cols.put("nombre_completo", "Nombre completo");
        cols.put("estado_label", "Estado");
        cols.put("jornada_nombre", "Jornada");
        cols.put("roles", "Roles");
        cols.put("sedes", "Sedes");
        def.setColumns(cols);
        return def;
    }

    /** Con usuario y filtros: asi el membrete y la linea de filtros se
     *  ejercitan de verdad y no solo la rama vacia. */
    private static ReportMeta meta() {
        Map<String, Object> filtros = new LinkedHashMap<>();
        filtros.put("search", "mar");
        filtros.put("statuses", List.of("Activo"));
        filtros.put("ids", List.of(1, 2, 3, 4, 5, 6, 7, 8));
        return new ReportMeta("laura@example.com", filtros);
    }

    @Test
    void elResumenDeFiltrosEsLegible() {
        String texto = meta().filtrosLegibles();
        assertTrue(texto.contains("Búsqueda: mar"), texto);
        assertTrue(texto.contains("Estados: Activo"), texto);
        // Una lista larga se resume: nadie lee 8 ids impresos, pero si
        // importa saber que el reporte salio de una seleccion manual.
        assertTrue(texto.contains("8 elementos seleccionados"), texto);
    }

    @Test
    void sinFiltrosElResumenQuedaVacio() {
        assertEquals("", new ReportMeta(null, Map.of()).filtrosLegibles());
        // Un filtro presente pero vacio es "sin filtrar": no debe ensuciar
        // el membrete con ruido que no cambio el resultado.
        assertEquals("", new ReportMeta(null, Map.of("search", "  ")).filtrosLegibles());
    }

    @Test
    void elPdfSaleValidoYNoVacio() {
        byte[] pdf = new PdfRenderer().render("funcionarios", definicion(), filas(), meta());

        // %PDF- es la firma del formato. Si Jasper fallara a mitad del
        // export, saldrian bytes sin cabecera y el visor diria "corrupto".
        assertTrue(pdf.length > 500, "el PDF salio sospechosamente chico: " + pdf.length);
        assertEquals("%PDF-", new String(pdf, 0, 5));
    }

    @Test
    void elPdfSinFilasIgualEsUnDocumentoAbrible() {
        // Un filtro sin resultados no debe producir un archivo de cero
        // paginas: eso es justo lo que los visores rechazan como corrupto.
        byte[] pdf = new PdfRenderer().render("vacio", definicion(), List.of(), meta());
        assertEquals("%PDF-", new String(pdf, 0, 5));
        assertTrue(pdf.length > 300);
    }

    @Test
    void elExcelSaleValidoYNoVacio() {
        byte[] xlsx = new ExcelRenderer().render("funcionarios", definicion(), filas(), meta());

        // Un .xlsx es un ZIP: empieza con PK\003\004.
        assertTrue(xlsx.length > 500, "el Excel salio sospechosamente chico: " + xlsx.length);
        assertEquals('P', (char) xlsx[0]);
        assertEquals('K', (char) xlsx[1]);
    }

    @Test
    void elExcelSinFilasNoRevienta() {
        // El autofiltro se aplica sobre un rango; con 0 filas de datos
        // POI rechaza el rango invertido si no se lo saltea.
        byte[] xlsx = new ExcelRenderer().render("vacio", definicion(), List.of(), meta());
        assertEquals('P', (char) xlsx[0]);
    }
}
