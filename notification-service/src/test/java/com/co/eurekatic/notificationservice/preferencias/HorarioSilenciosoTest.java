package com.co.eurekatic.notificationservice.preferencias;

import com.co.eurekatic.notificationservice.preferencias.PreferenciasRepository.Horario;
import org.junit.jupiter.api.Test;

import java.time.DayOfWeek;
import java.time.Instant;
import java.time.LocalTime;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class HorarioSilenciosoTest {

    private static Instant bogota(String local) {
        // Bogota es UTC-5 todo el ano.
        return Instant.parse(local + "Z").plusSeconds(5 * 3600L);
    }

    @Test
    void rangoQueCruzaMedianocheCuentaConElDiaDeInicio() {
        // Solo lunes (2): 22:00-06:00.
        Horario h = new Horario(true, LocalTime.of(22, 0), LocalTime.of(6, 0), List.of(2), "America/Bogota");
        // 2026-10-12 es lunes.
        assertThat(PreferenciasService.enHorarioSilencioso(h, bogota("2026-10-12T23:00:00"))).isTrue();
        assertThat(PreferenciasService.enHorarioSilencioso(h, bogota("2026-10-13T05:59:00"))).isTrue();
        assertThat(PreferenciasService.enHorarioSilencioso(h, bogota("2026-10-13T06:00:00"))).isFalse();
        assertThat(PreferenciasService.enHorarioSilencioso(h, bogota("2026-10-12T05:00:00"))).isFalse();
        assertThat(PreferenciasService.enHorarioSilencioso(h, bogota("2026-10-12T21:59:00"))).isFalse();
    }

    @Test
    void rangoDelMismoDiaEInactivo() {
        Horario h = new Horario(true, LocalTime.of(12, 0), LocalTime.of(14, 0), List.of(1, 2, 3, 4, 5, 6, 7), "America/Bogota");
        assertThat(PreferenciasService.enHorarioSilencioso(h, bogota("2026-10-15T13:00:00"))).isTrue();
        assertThat(PreferenciasService.enHorarioSilencioso(h, bogota("2026-10-15T14:00:00"))).isFalse();
        Horario apagado = new Horario(false, LocalTime.of(0, 0), LocalTime.of(23, 59), List.of(5), "America/Bogota");
        assertThat(PreferenciasService.enHorarioSilencioso(apagado, bogota("2026-10-15T13:00:00"))).isFalse();
    }

    @Test
    void domingoEsUno() {
        assertThat(PreferenciasService.diaBackend(DayOfWeek.SUNDAY)).isEqualTo(1);
        assertThat(PreferenciasService.diaBackend(DayOfWeek.MONDAY)).isEqualTo(2);
        assertThat(PreferenciasService.diaBackend(DayOfWeek.SATURDAY)).isEqualTo(7);
    }
}
