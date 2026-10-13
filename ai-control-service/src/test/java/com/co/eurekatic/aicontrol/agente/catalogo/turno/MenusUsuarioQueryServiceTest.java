package com.co.eurekatic.aicontrol.agente.catalogo.turno;

import com.co.eurekatic.aicontrol.agente.comun.PropiedadesAgenteFixture;
import com.co.eurekatic.aicontrol.client.QueryServiceClient;
import com.co.eurekatic.aicontrol.client.RespuestaQuery;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpMethod;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class MenusUsuarioQueryServiceTest {

    private final QueryServiceClient qs = mock(QueryServiceClient.class);
    private final MenusUsuarioQueryService menus = new MenusUsuarioQueryService(qs, PropiedadesAgenteFixture.propiedades());

    @Test
    void consultaLaRutaDeMenusConElTokenYCachea() {
        when(qs.invocar(eq(HttpMethod.GET), eq("/usuarios/permisos-menu"), any(), any(), eq("tkn"))).thenReturn(
                new RespuestaQuery.Exito(List.of(Map.of("codigo", "FUNCIONARIOS", "puede_ver", true,
                        "puede_crear", true, "puede_editar", true, "puede_eliminar", true))));

        Map<String, AccesoMenu> primera = menus.de("tkn");
        Map<String, AccesoMenu> segunda = menus.de("tkn");

        assertThat(primera).containsEntry("FUNCIONARIOS", new AccesoMenu(false));
        assertThat(segunda).isEqualTo(primera);
        verify(qs, times(1)).invocar(any(), anyString(), any(), any(), anyString());
    }

    @Test
    void unErrorDelServicioDaSinMenusYNoSeCachea() {
        when(qs.invocar(any(), anyString(), any(), any(), anyString())).thenReturn(
                new RespuestaQuery.ErrorCliente(403, "sin permiso"));

        assertThat(menus.de("otro")).isEmpty();
        assertThat(menus.de("otro")).isEmpty();
        verify(qs, times(2)).invocar(any(), anyString(), any(), any(), anyString());
    }
}
