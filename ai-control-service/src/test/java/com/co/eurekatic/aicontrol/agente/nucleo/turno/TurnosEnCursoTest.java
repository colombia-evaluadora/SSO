package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class TurnosEnCursoTest {

    private final TurnosEnCurso turnos = new TurnosEnCurso();

    @Test
    void unSegundoTurnoDelMismoUsuarioSeRechazaHastaQueTermineElPrimero() {
        try (TurnosEnCurso.Turno _ = turnos.abrir(7L)) {
            assertThatThrownBy(() -> turnos.abrir(7L)).isInstanceOf(ErrorAgente.TurnoEnCurso.class);
            assertThatCode(() -> turnos.abrir(8L).close()).as("otro usuario").doesNotThrowAnyException();
        }
        assertThatCode(() -> turnos.abrir(7L).close()).doesNotThrowAnyException();
    }

    @Test
    void elTurnoSeLiberaAunqueFalle() {
        assertThatThrownBy(() -> {
            try (TurnosEnCurso.Turno _ = turnos.abrir(9L)) {
                throw new IllegalStateException("fallo del turno");
            }
        }).isInstanceOf(IllegalStateException.class);
        assertThatCode(() -> turnos.abrir(9L).close()).doesNotThrowAnyException();
    }
}
