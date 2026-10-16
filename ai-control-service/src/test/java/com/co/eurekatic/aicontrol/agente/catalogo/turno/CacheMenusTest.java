package com.co.eurekatic.aicontrol.agente.catalogo.turno;

import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class CacheMenusTest {

    /** Reloj movible para probar la caducidad sin esperar. */
    private static final class RelojMovil extends Clock {
        private Instant ahora = Instant.parse("2026-10-13T12:00:00Z");

        @Override
        public ZoneId getZone() {
            return ZoneId.of("UTC");
        }

        @Override
        public Clock withZone(ZoneId zone) {
            return this;
        }

        @Override
        public Instant instant() {
            return ahora;
        }
    }

    @Test
    void unaEntradaVenceAlCumplirseElTtl() {
        RelojMovil reloj = new RelojMovil();
        CacheMenus<String> cache = new CacheMenus<>(Duration.ofSeconds(60), reloj);
        Map<String, AccesoMenu> menus = Map.of("FUNCIONARIOS", new AccesoMenu(true));
        cache.poner("h1", menus);

        reloj.ahora = reloj.ahora.plusSeconds(59);
        assertThat(cache.obtener("h1")).contains(menus);

        reloj.ahora = reloj.ahora.plusSeconds(1);
        assertThat(cache.obtener("h1")).isEmpty();
    }

    @Test
    void unaClaveAusenteNoEsUnaEntrada() {
        CacheMenus<String> cache = new CacheMenus<>(Duration.ofSeconds(60), new RelojMovil());

        assertThat(cache.obtener("nada")).isEmpty();
    }
}
