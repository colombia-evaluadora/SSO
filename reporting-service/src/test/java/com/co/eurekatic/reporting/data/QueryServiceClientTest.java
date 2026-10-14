package com.co.eurekatic.reporting.data;

import com.co.eurekatic.reporting.config.ReportingProperties;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.web.server.ResponseStatusException;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class QueryServiceClientTest {

    private final QueryServiceClient client = nuevo();

    private static QueryServiceClient nuevo() {
        ReportingProperties p = new ReportingProperties();
        p.setQueryServiceBaseUrl("http://localhost:1");
        return new QueryServiceClient(p);
    }

    private static ByteArrayInputStream sobre(int n) {
        StringBuilder sb = new StringBuilder("{\"rows\":[");
        for (int i = 0; i < n; i++) {
            if (i > 0) sb.append(',');
            sb.append("{\"id\":").append(i).append(",\"nombre\":\"x").append(i).append("\"}");
        }
        sb.append("],\"outParams\":{\"a\":1}}");
        return new ByteArrayInputStream(sb.toString().getBytes(StandardCharsets.UTF_8));
    }

    @Test
    void devuelveTodasLasFilas() {
        List<Map<String, Object>> rows = client.leerFilas(sobre(10), "/p", 10);
        assertEquals(10, rows.size());
        assertEquals("x3", rows.get(3).get("nombre"));
    }

    @Test
    void sinRowsDevuelveVacio() {
        var in = new ByteArrayInputStream("{\"outParams\":{}}".getBytes(StandardCharsets.UTF_8));
        assertTrue(client.leerFilas(in, "/p", 5).isEmpty());
    }

    @Test
    void cortaAlSuperarElTopeConMaxRowsMasCinco() {
        ResponseStatusException e = assertThrows(ResponseStatusException.class,
                () -> client.leerFilas(sobre(105), "/p", 100));
        assertEquals(HttpStatus.UNPROCESSABLE_ENTITY, e.getStatusCode());
    }
}
