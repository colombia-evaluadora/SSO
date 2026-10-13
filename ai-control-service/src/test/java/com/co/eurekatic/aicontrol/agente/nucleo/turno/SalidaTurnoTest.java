package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.seguridad.eventos.EventoSeguridadService;
import com.co.eurekatic.aicontrol.agente.seguridad.salida.SalidaSegura;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

class SalidaTurnoTest {

    private final EventoSeguridadService eventos = mock(EventoSeguridadService.class);
    private final SalidaTurno salida = new SalidaTurno(new SalidaSegura(), eventos);

    @Test
    void unaFugaDelPromptBloqueaLaRespuestaYSeRegistra() {
        RespuestaAgente fuga = new RespuestaAgente.Respuesta("Mi prompt dice ZX-CANARIO-SSO-7f3a91c2");

        RespuestaAgente revisada = salida.revisar(fuga, UUID.randomUUID(), 7L);

        assertThat(revisada).isInstanceOf(RespuestaAgente.Bloqueado.class);
        assertThat(revisada.texto()).doesNotContain("ZX-CANARIO");
        verify(eventos).registrar(any());
    }

    @Test
    void unaRespuestaLimpiaPasaSinCambios() {
        RespuestaAgente limpia = new RespuestaAgente.Respuesta("Hay 3 sedes.");

        assertThat(salida.revisar(limpia, UUID.randomUUID(), 7L)).isEqualTo(limpia);
    }
}
