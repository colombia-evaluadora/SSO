package com.co.eurekatic.reporting.verificacion;

import com.co.eurekatic.reporting.ReportingServiceApplication;
import com.co.eurekatic.reporting.data.QueryServiceClient;
import com.co.eurekatic.reporting.render.PdfRenderer;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.web.context.WebApplicationContext;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.reset;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.setup.SecurityMockMvcConfigurers.springSecurity;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Verificacion publica del boletin de punta a punta en el servicio (sin red):
 * sin token responde el estado y, con el segundo factor, el PDF; el resto de
 * /reportes sigue exigiendo sesion; y el freno por intentos fallidos.
 */
@SpringBootTest(classes = ReportingServiceApplication.class,
        webEnvironment = SpringBootTest.WebEnvironment.MOCK)
@TestPropertySource(locations = "classpath:jwt-test-keys.properties", properties = {
        "eureka.client.enabled=false",
        "spring.cloud.discovery.enabled=false",
        "reporting.verificacion.base-url=https://testv2.colombiaevaluadora.com/verificar/b",
        "reporting.verificacion.limite-por-ip-minuto=1000",
        "reporting.verificacion.intentos-fallidos-max=5"
})
class VerificacionPublicaIntegrationTest {

    static final String CODIGO = "AbCdEfGhIjKlMnOpQrStUvWx";
    static final String CONSULTAR = "eval-col-boletin-verificacion-consultar-001";
    static final String DATOS = "eval-col-boletin-verificacion-datos-001";

    @Autowired WebApplicationContext context;

    @MockitoBean QueryServiceClient queryService;
    @MockitoBean PdfRenderer pdf;

    MockMvc mvc;

    @BeforeEach
    void setUp() {
        reset(queryService, pdf);
        mvc = MockMvcBuilders.webAppContextSetup(context).apply(springSecurity()).build();
    }

    private void emisionVigente(String codigo) {
        when(queryService.publicRows(isNull(), eq(CONSULTAR), eq(Map.of("BODY.CODIGO", codigo)), anyInt()))
                .thenReturn(List.of(Map.of(
                        "estado", "VIGENTE", "nivel", "primaria",
                        "emitido_en", "2026-10-13T18:00:00", "institucion", "IE Simon Bolivar",
                        "sede", "Principal", "periodo", "Primer periodo", "anio", 2026)));
    }

    @Test
    void estadoSinTokenSinDatosDelEstudiante() throws Exception {
        emisionVigente(CODIGO);
        mvc.perform(get("/reportes/public/boletin/" + CODIGO))
                .andExpect(status().isOk())
                .andExpect(header().string("Cache-Control", "no-store"))
                .andExpect(jsonPath("$.estado").value("VIGENTE"))
                .andExpect(jsonPath("$.emitidoEn").value("2026-10-13T18:00:00"))
                .andExpect(jsonPath("$.institucion").value("IE Simon Bolivar"))
                .andExpect(jsonPath("$.sede").value("Principal"))
                .andExpect(jsonPath("$.periodo").value("Primer periodo 2026"))
                .andExpect(jsonPath("$.actualizadoEn").doesNotExist())
                .andExpect(jsonPath("$.nivel").doesNotExist())
                .andExpect(jsonPath("$.estudiante").doesNotExist())
                .andExpect(jsonPath("$.documento").doesNotExist());
    }

    @Test
    void codigoInexistenteOMalFormadoEsNoValido() throws Exception {
        when(queryService.publicRows(any(), any(), anyMap(), anyInt())).thenReturn(List.of());
        mvc.perform(get("/reportes/public/boletin/ZZZZZZZZZZZZZZZZZZZZZZZZ"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.estado").value("NO_VALIDO"));
        mvc.perform(get("/reportes/public/boletin/abc"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.estado").value("NO_VALIDO"));
        // Mal formado ni siquiera llega a la base.
        verify(queryService, never()).publicRows(any(), any(), eq(Map.of("BODY.CODIGO", "abc")), anyInt());
        mvc.perform(post("/reportes/public/boletin/ZZZZZZZZZZZZZZZZZZZZZZZZ/pdf")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"ultimos4\":\"1234\"}"))
                .andExpect(status().isNotFound());
    }

    @Test
    void pdfConDigitosCorrectosSaleConMarcaDeAgua() throws Exception {
        String codigo = "PdfOkPdfOkPdfOkPdfOk1234";
        emisionVigente(codigo);
        when(queryService.publicRows(isNull(), eq(DATOS), anyMap(), anyInt()))
                .thenReturn(List.of(Map.of("factor_ok", true, "orden", 1,
                        "fila", Map.of("matricula", 7, "estudiante", "ANA", "nota", "4.5"))));
        when(pdf.render(any(), any(), any(), any(), any(), any(), anyMap())).thenReturn("%PDF-1.7".getBytes());

        mvc.perform(post("/reportes/public/boletin/" + codigo + "/pdf")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"ultimos4\":\"5678\"}"))
                .andExpect(status().isOk())
                .andExpect(content().contentType(MediaType.APPLICATION_PDF));

        // A la base solo viajan el codigo y los digitos: nunca un id.
        verify(queryService).publicRows(isNull(), eq(DATOS),
                eq(Map.of("BODY.CODIGO", codigo, "BODY.ULTIMOS4", "5678")), anyInt());
        @SuppressWarnings("unchecked")
        ArgumentCaptor<Map<String, Object>> extra = ArgumentCaptor.forClass(Map.class);
        @SuppressWarnings("unchecked")
        ArgumentCaptor<List<Map<String, Object>>> filas = ArgumentCaptor.forClass(List.class);
        verify(pdf).render(eq("boletin-notas"), any(), filas.capture(), any(), any(), any(), extra.capture());
        assertThat((String) extra.getValue().get("MARCA_VERIFICACION"))
                .startsWith("Copia de verificación — generada ");
        assertThat(filas.getValue().get(0)).containsEntry("codigo_verificacion", codigo)
                .containsEntry("url_verificacion", "https://testv2.colombiaevaluadora.com/verificar/b/" + codigo);
    }

    @Test
    void digitosIncorrectos403YTrasCincoFallos429() throws Exception {
        String codigo = "FalloFalloFalloFallo1234";
        emisionVigente(codigo);
        when(queryService.publicRows(isNull(), eq(DATOS), anyMap(), anyInt()))
                .thenReturn(List.of(java.util.Collections.singletonMap("factor_ok", false)));
        for (int i = 0; i < 5; i++) {
            mvc.perform(post("/reportes/public/boletin/" + codigo + "/pdf")
                            .contentType(MediaType.APPLICATION_JSON).content("{\"ultimos4\":\"0000\"}"))
                    .andExpect(status().isForbidden());
        }
        mvc.perform(post("/reportes/public/boletin/" + codigo + "/pdf")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"ultimos4\":\"5678\"}"))
                .andExpect(status().isTooManyRequests())
                .andExpect(header().exists("Retry-After"));
    }

    @Test
    void elRestoDeReportesSigueExigiendoSesion() throws Exception {
        int s1 = mvc.perform(post("/reportes/boletin").param("nivel", "primaria")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"format\":\"pdf\"}"))
                .andReturn().getResponse().getStatus();
        int s2 = mvc.perform(post("/reportes/boletin/emisiones/" + CODIGO + "/revocar")
                        .contentType(MediaType.APPLICATION_JSON).content("{\"motivo\":\"x\"}"))
                .andReturn().getResponse().getStatus();
        int s3 = mvc.perform(get("/reportes/public/boletin/" + CODIGO + "/pdf"))
                .andReturn().getResponse().getStatus();
        assertThat(s1).isIn(401, 403);
        assertThat(s2).isIn(401, 403);
        assertThat(s3).isIn(401, 403);
        verify(queryService, never()).fetchRows(any(), any(), any(), any(), any(), anyInt());
        verify(queryService, never()).postRows(any(), any(), any(), any(), anyInt());
    }
}
