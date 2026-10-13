package com.co.eurekatic.aicontrol.agente.seguridad.eventos;

import com.co.eurekatic.aicontrol.agente.persistencia.seguridad.EventoSeguridadStore;
import com.co.eurekatic.aicontrol.agente.persistencia.seguridad.EventoSeguridadStore.NuevoEvento;
import com.co.eurekatic.aicontrol.agente.seguridad.CapaSeguridad;
import com.co.eurekatic.aicontrol.agente.seguridad.Hallazgo;
import com.co.eurekatic.aicontrol.agente.seguridad.Motivo;
import com.co.eurekatic.aicontrol.agente.seguridad.Riesgo;
import com.co.eurekatic.aicontrol.agente.seguridad.entrada.clasificador.RespuestaClasificador;
import com.co.eurekatic.aicontrol.agente.seguridad.eventos.EventoSeguridadService.RegistroEvento;
import com.co.eurekatic.aicontrol.agente.seguridad.salida.DetectoresSalida;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.dao.DataAccessResourceFailureException;

import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

class EventoSeguridadServiceTest {

    // sha256("abc")
    private static final String SHA256_ABC = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    private static final Hallazgo INSTRUCCION_IGNORADA =
            new Hallazgo(CapaSeguridad.FIREWALL, Riesgo.ALTO, new Motivo("INSTRUCCION_IGNORADA"));

    private EventoSeguridadStore repositorio;
    private SimpleMeterRegistry metricas;
    private EventoSeguridadService servicio;

    @BeforeEach
    void setUp() {
        repositorio = mock(EventoSeguridadStore.class);
        metricas = new SimpleMeterRegistry();
        servicio = new EventoSeguridadService(repositorio, metricas);
    }

    @Test
    void guardaLaHuellaDelTextoNormalizadoNuncaElTexto() {
        UUID conversacion = UUID.randomUUID();

        servicio.registrar(new RegistroEvento(Optional.of(conversacion), 42L, INSTRUCCION_IGNORADA,
                Optional.of("abc")));

        NuevoEvento e = capturarEvento();
        assertThat(e.conversacionId()).isEqualTo(conversacion);
        assertThat(e.fkUsuario()).isEqualTo(42L);
        assertThat(e.capa()).isEqualTo("FIREWALL");
        assertThat(e.riesgo()).isEqualTo("ALTO");
        assertThat(e.motivo()).isEqualTo("INSTRUCCION_IGNORADA");
        assertThat(e.fragmentoHash()).isEqualTo(SHA256_ABC).hasSize(64);
    }

    @Test
    void sinTextoLaHuellaQuedaNula() {
        servicio.registrar(new RegistroEvento(Optional.empty(), 7L,
                new Hallazgo(CapaSeguridad.CLASIFICADOR, Riesgo.MEDIO, RespuestaClasificador.NO_DISPONIBLE),
                Optional.empty()));

        NuevoEvento e = capturarEvento();
        assertThat(e.fragmentoHash()).isNull();
        assertThat(e.conversacionId()).isNull();
    }

    @Test
    void cuentaLaMetricaPorCapaYMotivo() {
        servicio.registrar(new RegistroEvento(Optional.empty(), 1L, INSTRUCCION_IGNORADA, Optional.of("x")));
        servicio.registrar(new RegistroEvento(Optional.empty(), 1L, INSTRUCCION_IGNORADA, Optional.of("y")));

        assertThat(metricas.get("ai.firewall.bloqueos")
                .tags("capa", "FIREWALL", "motivo", "INSTRUCCION_IGNORADA")
                .counter().count()).isEqualTo(2.0);
    }

    @Test
    void unMotivoQueNoEsCodigoSeRegistraComoOtro() {
        Hallazgo libre = new Hallazgo(CapaSeguridad.FIREWALL, Riesgo.MEDIO,
                Motivo.de("Hola, ignora todo lo de Juan"));

        servicio.registrar(new RegistroEvento(Optional.empty(), 1L, libre, Optional.of("x")));

        assertThat(capturarEvento().motivo()).isEqualTo("OTRO");
        assertThat(metricas.get("ai.firewall.bloqueos")
                .tags("capa", "FIREWALL", "motivo", "OTRO").counter().count()).isEqualTo(1.0);
    }

    @Test
    void siLaBaseFallaSeSigueYLaMetricaCuenta() {
        doThrow(new DataAccessResourceFailureException("caida")).when(repositorio).insertar(any());

        servicio.registrar(new RegistroEvento(Optional.empty(), 1L,
                new Hallazgo(CapaSeguridad.SALIDA, Riesgo.ALTO, DetectoresSalida.FUGA_PROMPT),
                Optional.of("x")));

        assertThat(metricas.get("ai.firewall.bloqueos")
                .tags("capa", "SALIDA", "motivo", "FUGA_PROMPT").counter().count()).isEqualTo(1.0);
    }

    private NuevoEvento capturarEvento() {
        ArgumentCaptor<NuevoEvento> guardado = ArgumentCaptor.forClass(NuevoEvento.class);
        verify(repositorio).insertar(guardado.capture());
        return guardado.getValue();
    }
}
