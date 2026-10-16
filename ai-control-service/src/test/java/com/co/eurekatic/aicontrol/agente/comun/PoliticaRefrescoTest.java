package com.co.eurekatic.aicontrol.agente.comun;

import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.time.Instant;

import static org.assertj.core.api.Assertions.assertThat;

class PoliticaRefrescoTest {

    private static final Instant ULTIMA = Instant.parse("2026-10-13T12:00:00Z");
    private static final Duration CINCO_MINUTOS = Duration.ofMinutes(5);

    @Test
    void vacioSeRecargaAunqueNoHayaVencidoElIntervalo() {
        assertThat(PoliticaRefresco.toca(true, ULTIMA, ULTIMA, CINCO_MINUTOS)).isTrue();
    }

    @Test
    void cargadoSeRecargaSoloAlVencerElIntervalo() {
        assertThat(PoliticaRefresco.toca(false, ULTIMA, ULTIMA.plusSeconds(60), CINCO_MINUTOS)).isFalse();
        assertThat(PoliticaRefresco.toca(false, ULTIMA, ULTIMA.plusSeconds(300), CINCO_MINUTOS)).isTrue();
    }
}
