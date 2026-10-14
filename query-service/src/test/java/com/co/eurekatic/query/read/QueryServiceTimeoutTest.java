package com.co.eurekatic.query.read;

import com.co.eurekatic.query.catalog.CatalogDefinitionCache;
import com.co.eurekatic.query.config.JdbcTemplateRegistry;
import com.co.eurekatic.query.observability.QueryMetrics;
import com.co.eurekatic.query.resilience.QueryResilience;
import com.co.eurekatic.query.routing.CatalogResultCacheService;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

/**
 * Timeout por sentencia: corto para las pantallas, largo para reportes
 * (cabecera) y para las rutas de operaciones en lote (patrón de ruta).
 */
class QueryServiceTimeoutTest {

    private final QueryService service = new QueryService(
            mock(CatalogDefinitionCache.class), mock(JdbcTemplateRegistry.class),
            mock(QueryMetrics.class), mock(QueryResilience.class),
            new ObjectMapper(), mock(CatalogResultCacheService.class));

    @AfterEach
    void limpiar() {
        RequestContextHolder.resetRequestAttributes();
    }

    @Test
    void consultaDePantallaUsaElTimeoutCorto() {
        assertThat(service.resolveTimeoutSeconds("/areas/general")).isEqualTo(15);
        assertThat(service.resolveTimeoutSeconds(null)).isEqualTo(15);
    }

    @Test
    void rutasDeExportarImportarYLoteUsanElTimeoutLargo() {
        assertThat(service.resolveTimeoutSeconds("/planeador/actividades/export-all")).isEqualTo(170);
        assertThat(service.resolveTimeoutSeconds("/planeador/actividades/importar")).isEqualTo(170);
        assertThat(service.resolveTimeoutSeconds("/grupos/bulk-delete")).isEqualTo(170);
        assertThat(service.resolveTimeoutSeconds("/aprobaciones/aprobar-masivo")).isEqualTo(170);
        assertThat(service.resolveTimeoutSeconds("/grados/eliminacion-masiva")).isEqualTo(170);
        assertThat(service.resolveTimeoutSeconds("/informes/boletin-preescolar")).isEqualTo(170);
    }

    @Test
    void cabeceraDeReporteUsaElTimeoutLargo() {
        MockHttpServletRequest req = new MockHttpServletRequest();
        req.addHeader(QueryService.TIMEOUT_PROFILE_HEADER, "report");
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(req));
        assertThat(service.resolveTimeoutSeconds("/areas/general")).isEqualTo(170);
    }

    @Test
    void patronVacioDesactivaElPerfilPorRuta() {
        service.setLongPathPattern("");
        assertThat(service.resolveTimeoutSeconds("/grupos/bulk-delete")).isEqualTo(15);
    }
}
