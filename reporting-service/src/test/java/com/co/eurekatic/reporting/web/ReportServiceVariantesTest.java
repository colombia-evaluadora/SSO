package com.co.eurekatic.reporting.web;

import com.co.eurekatic.reporting.config.ReportingProperties;
import com.co.eurekatic.reporting.data.QueryServiceClient;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.web.server.ResponseStatusException;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * Un endpoint para varios reportes: {@code POST /reportes/boletin?nivel=...}
 * elige por el query param el reporte que lo atiende (el de preescolar o el
 * de los demas niveles), cada uno con su funcion y su plantilla.
 */
class ReportServiceVariantesTest {

    /** Corta la generacion apenas se pide la consulta: solo importa la ruta. */
    private static final class Consultado extends RuntimeException {
        final String path;

        Consultado(String path) {
            this.path = path;
        }
    }

    private ReportService servicio() {
        ReportingProperties props = new ReportingProperties();
        Map<String, ReportingProperties.Report> reportes = new LinkedHashMap<>();

        ReportingProperties.Report boletin = new ReportingProperties.Report();
        boletin.setVariantParam("nivel");
        Map<String, String> variantes = new LinkedHashMap<>();
        variantes.put("preescolar", "boletin-preescolar");
        variantes.put("primaria", "boletin-notas");
        variantes.put("media", "boletin-notas");
        boletin.setVariants(variantes);
        reportes.put("boletin", boletin);

        for (String clave : List.of("boletin-preescolar", "boletin-notas")) {
            ReportingProperties.Report r = new ReportingProperties.Report();
            r.setPath("/informes/" + clave);
            r.setFormats(new java.util.ArrayList<>(List.of("pdf")));
            reportes.put(clave, r);
        }
        props.setReports(reportes);

        QueryServiceClient query = mock(QueryServiceClient.class);
        when(query.fetchRows(any(), anyString(), any(), any(), any()))
                .thenAnswer(inv -> {
                    throw new Consultado(inv.getArgument(1));
                });
        return new ReportService(props, query, null, null, null);
    }

    private String rutaConsultada(String nivel) {
        Map<String, String> q = nivel == null ? Map.of() : Map.of("nivel", nivel);
        Consultado c = assertThrows(Consultado.class,
                () -> servicio().generate("boletin", q, null, "token", "u@x.co"));
        return c.path;
    }

    @Test
    void cadaNivelUsaSuBoletin() {
        assertEquals("/informes/boletin-preescolar", rutaConsultada("preescolar"));
        assertEquals("/informes/boletin-notas", rutaConsultada("primaria"));
        assertEquals("/informes/boletin-notas", rutaConsultada("MEDIA"));
    }

    @Test
    void sinNivelONivelDesconocidoEs400ConLosValoresValidos() {
        for (Map<String, String> q : List.of(Map.<String, String>of(), Map.of("nivel", "universidad"))) {
            ResponseStatusException e = assertThrows(ResponseStatusException.class,
                    () -> servicio().generate("boletin", q, null, "token", "u@x.co"));
            assertEquals(HttpStatus.BAD_REQUEST, e.getStatusCode());
            assertTrue(e.getReason().contains("preescolar, primaria, media"), e.getReason());
        }
    }

    @Test
    void unReporteSinVariantesIgnoraElQueryParam() {
        Consultado c = assertThrows(Consultado.class,
                () -> servicio().generate("boletin-notas", Map.of("nivel", "preescolar"), null, "t", "u"));
        assertEquals("/informes/boletin-notas", c.path);
    }
}
