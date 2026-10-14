package com.co.eurekatic.reporting.verificacion;

import com.co.eurekatic.reporting.config.ReportingProperties;
import com.github.benmanes.caffeine.cache.Ticker;
import org.junit.jupiter.api.Test;
import org.springframework.web.server.ResponseStatusException;

import java.time.Duration;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class VerificacionBoletinTest {

    @Test
    void formatoDelCodigoYDelFactor() {
        assertTrue(VerificacionBoletin.codigoValido("AbCdEfGhIjKlMnOpQrStUv-_"));
        assertFalse(VerificacionBoletin.codigoValido("123"));
        assertFalse(VerificacionBoletin.codigoValido("' OR 1=1 --AAAAAAAAAAAAAA"));
        assertFalse(VerificacionBoletin.codigoValido(null));
        assertTrue(VerificacionBoletin.ultimos4Validos("5678"));
        assertFalse(VerificacionBoletin.ultimos4Validos("567"));
        assertFalse(VerificacionBoletin.ultimos4Validos("56789"));
    }

    @Test
    void laClaveEsLaDeLaPlantilla() {
        Map<String, Object> notas = Map.of("matricula", 123, "documento", "1", "estudiante", "A");
        assertEquals("123", VerificacionBoletin.clave("primaria", notas));
        Map<String, Object> pre = new HashMap<>();
        pre.put("documento", "1045");
        pre.put("estudiante", "ANA");
        assertEquals("1045|ANA", VerificacionBoletin.clave("preescolar", pre));
        pre.put("documento", null);
        assertEquals("|ANA", VerificacionBoletin.clave("preescolar", pre));
    }

    @Test
    void marcaSoloLasFilasConCodigoYArmaLaUrl() {
        List<Map<String, Object>> filas = new ArrayList<>();
        filas.add(new LinkedHashMap<>(Map.of("matricula", 1)));
        filas.add(new LinkedHashMap<>(Map.of("matricula", 1)));
        filas.add(new LinkedHashMap<>(Map.of("matricula", 2)));
        VerificacionBoletin.marcar(filas, "media", Map.of("1", "COD1"), "https://x/verificar/b/");
        assertEquals("COD1", filas.get(1).get("codigo_verificacion"));
        assertEquals("https://x/verificar/b/COD1", filas.get(0).get("url_verificacion"));
        assertNull(filas.get(2).get("codigo_verificacion"));
    }

    @Test
    void limitePorIpYPorIntentosConVentana() {
        ReportingProperties.Verificacion v = new ReportingProperties.Verificacion();
        v.setLimitePorIpMinuto(3);
        v.setIntentosFallidosMax(5);
        v.setVentanaIntentos(Duration.ofMinutes(15));
        AtomicLong nanos = new AtomicLong();
        Ticker reloj = nanos::get;
        LimitesVerificacion l = new LimitesVerificacion(v, reloj);

        for (int i = 0; i < 3; i++) {
            l.contarPeticion("1.2.3.4");
        }
        ResponseStatusException e = assertThrows(ResponseStatusException.class, () -> l.contarPeticion("1.2.3.4"));
        assertEquals(429, e.getStatusCode().value());
        assertDoesNotThrow(() -> l.contarPeticion("5.6.7.8"));
        nanos.addAndGet(Duration.ofSeconds(61).toNanos());
        assertDoesNotThrow(() -> l.contarPeticion("1.2.3.4"));

        for (int i = 0; i < 5; i++) {
            l.exigirIntentosDisponibles("C");
            l.registrarFallo("C");
        }
        assertThrows(ResponseStatusException.class, () -> l.exigirIntentosDisponibles("C"));
        nanos.addAndGet(Duration.ofMinutes(16).toNanos());
        assertDoesNotThrow(() -> l.exigirIntentosDisponibles("C"));
    }
}
