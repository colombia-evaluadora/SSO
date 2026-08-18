package com.co.eurekatic.files;

import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;

import static org.assertj.core.api.Assertions.assertThat;

class ViewTokenServiceTest {

    private static final String SECRETO = "secreto-de-prueba-no-vacio";

    private static ViewTokenService servicio(long ttlSegundos, Instant ahora) {
        return new ViewTokenService(SECRETO, ttlSegundos, Clock.fixed(ahora, ZoneOffset.UTC));
    }

    @Test
    void sinSecretoConfiguradoQuedaDeshabilitado() {
        var servicio = new ViewTokenService("", 300, Clock.systemUTC());
        assertThat(servicio.habilitado()).isFalse();
        // Falla cerrado: ni siquiera intenta validar sin secreto.
        assertThat(servicio.valido("cualquier.cosa", 1L)).isFalse();
    }

    @Test
    void unTokenRecienAcunadoEsValidoParaSuArchivo() {
        var servicio = servicio(300, Instant.parse("2026-01-01T00:00:00Z"));
        String token = servicio.acunar(42L);

        assertThat(servicio.valido(token, 42L)).isTrue();
    }

    /**
     * El caso que motiva todo el diseño: el token se firma para UN
     * archivo. Presentarlo para pedir otro (aunque la firma sea
     * perfectamente válida) tiene que rechazarse — si no, cualquiera
     * con un token de vista de SU propia foto podría verla ajena
     * cambiando el número en la URL.
     */
    @Test
    void unTokenValidoParaOtroArchivoEsRechazado() {
        var servicio = servicio(300, Instant.parse("2026-01-01T00:00:00Z"));
        String token = servicio.acunar(42L);

        assertThat(servicio.valido(token, 99L)).isFalse();
    }

    @Test
    void unTokenCaducadoEsRechazado() {
        Instant emision = Instant.parse("2026-01-01T00:00:00Z");
        var servicioQueAcuna = servicio(60, emision);
        String token = servicioQueAcuna.acunar(42L);

        // Mismo secreto, reloj 61s después: el mismo token, ahora tarde.
        var servicioMasTarde = new ViewTokenService(
                SECRETO, 60, Clock.fixed(emision.plusSeconds(61), ZoneOffset.UTC));

        assertThat(servicioMasTarde.valido(token, 42L)).isFalse();
    }

    @Test
    void justoEnElLimiteDelTtlSigueSiendoValido() {
        Instant emision = Instant.parse("2026-01-01T00:00:00Z");
        String token = servicio(60, emision).acunar(42L);

        var servicioEnElLimite = new ViewTokenService(
                SECRETO, 60, Clock.fixed(emision.plusSeconds(60), ZoneOffset.UTC));

        assertThat(servicioEnElLimite.valido(token, 42L)).isTrue();
    }

    @Test
    void unTokenConLaFirmaAlteradaEsRechazado() {
        var servicio = servicio(300, Instant.parse("2026-01-01T00:00:00Z"));
        String token = servicio.acunar(42L);
        String firmaRota = token.substring(0, token.length() - 1)
                + (token.charAt(token.length() - 1) == 'A' ? 'B' : 'A');

        assertThat(servicio.valido(firmaRota, 42L)).isFalse();
    }

    /**
     * Cambiar el archivoId del payload (sin volver a firmar) es el
     * intento de falsificación más directo: si esto pasara, el HMAC no
     * estaría protegiendo nada. La firma antigua no calza con el
     * payload nuevo, así que se rechaza — no por el chequeo de
     * archivoId, sino por el de firma, que corre primero.
     */
    @Test
    void alterarElArchivoIdDelPayloadInvalidaLaFirma() {
        var servicio = servicio(300, Instant.parse("2026-01-01T00:00:00Z"));
        String token = servicio.acunar(42L);
        int punto = token.indexOf('.');
        String payloadFalsificado = java.util.Base64.getUrlEncoder().withoutPadding()
                .encodeToString("99:9999999999".getBytes());
        String tokenFalsificado = payloadFalsificado + token.substring(punto);

        assertThat(servicio.valido(tokenFalsificado, 99L)).isFalse();
    }

    @Test
    void formatosMalformadosSonRechazadosSinLanzarExcepcion() {
        var servicio = servicio(300, Instant.parse("2026-01-01T00:00:00Z"));

        assertThat(servicio.valido(null, 1L)).isFalse();
        assertThat(servicio.valido("", 1L)).isFalse();
        assertThat(servicio.valido("sin-punto-separador", 1L)).isFalse();
        assertThat(servicio.valido("***.***", 1L)).isFalse();
    }

    @Test
    void dosTokensParaElMismoArchivoSonDistintosPorLaExpiracion() {
        var servicio = servicio(300, Instant.parse("2026-01-01T00:00:00Z"));
        // Emitidos en el mismo tick de reloj, así que la única forma de
        // que salieran iguales sería que el archivoId no entrara en el
        // payload firmado — bug que este test detectaría por accidente
        // si acunar() alguna vez dejara de incluirlo.
        String tokenA = servicio.acunar(1L);
        String tokenB = servicio.acunar(2L);

        assertThat(tokenA).isNotEqualTo(tokenB);
        assertThat(servicio.valido(tokenA, 2L)).isFalse();
        assertThat(servicio.valido(tokenB, 1L)).isFalse();
    }
}
