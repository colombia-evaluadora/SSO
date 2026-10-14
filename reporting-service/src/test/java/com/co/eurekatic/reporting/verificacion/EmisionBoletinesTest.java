package com.co.eurekatic.reporting.verificacion;

import com.co.eurekatic.reporting.config.ReportingProperties;
import com.co.eurekatic.reporting.data.QueryServiceClient;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.web.server.ResponseStatusException;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Un fallo del registro de emisiones no puede tumbar la impresion del boletin. */
class EmisionBoletinesTest {

    @Test
    void falloDelRegistroDevuelveLasFilasSinQr() {
        ReportingProperties props = new ReportingProperties();
        props.getVerificacion().setBaseUrl("https://ejemplo.co/verificar");
        QueryServiceClient qs = mock(QueryServiceClient.class);
        when(qs.postRows(any(), any(), any(), any(), anyInt()))
                .thenThrow(new ResponseStatusException(HttpStatus.FORBIDDEN, "sin acceso"));

        Map<String, Object> fila = new LinkedHashMap<>();
        fila.put("pk_tmatricula", 1);
        List<Map<String, Object>> rows = new ArrayList<>(List.of(fila));

        List<Map<String, Object>> out = new EmisionBoletines(props, qs)
                .marcar("NOTAS", Map.of("FK_TGRUPO", 1, "FK_TPERIODO_EVALUACION", 2), rows, "tok");

        assertThat(out).hasSize(1);
        assertThat(out.get(0)).doesNotContainKeys("codigo_verificacion", "url_verificacion");
    }
}
