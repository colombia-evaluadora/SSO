package com.co.eurekatic.aicontrol.agente.seguridad;

import com.co.eurekatic.aicontrol.agente.persistencia.EventoSeguridadRepository;
import com.co.eurekatic.aicontrol.agente.persistencia.EventoSeguridadRepository.NuevoEvento;
import com.co.eurekatic.aicontrol.agente.seguridad.EventoSeguridadService.RegistroEvento;
import io.micrometer.core.instrument.simple.SimpleMeterRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.dao.DataAccessResourceFailureException;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

class EventoSeguridadServiceTest {

    // sha256("abc")
    private static final String SHA256_ABC = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    private EventoSeguridadRepository repositorio;
    private SimpleMeterRegistry metricas;
    private EventoSeguridadService servicio;

    @BeforeEach
    void setUp() {
        repositorio = mock(EventoSeguridadRepository.class);
        metricas = new SimpleMeterRegistry();
        servicio = new EventoSeguridadService(repositorio, metricas);
    }

    @Test
    void guardaLaHuellaDelTextoNormalizadoNuncaElTexto() {
        UUID conversacion = UUID.randomUUID();

        servicio.registrar(new RegistroEvento(conversacion, 42L, CapaSeguridad.FIREWALL, Riesgo.ALTO,
                "INSTRUCCION_IGNORADA", "abc"));

        ArgumentCaptor<NuevoEvento> guardado = ArgumentCaptor.forClass(NuevoEvento.class);
        verify(repositorio).insertar(guardado.capture());
        NuevoEvento e = guardado.getValue();
        assertThat(e.conversacionId()).isEqualTo(conversacion);
        assertThat(e.fkUsuario()).isEqualTo(42L);
        assertThat(e.capa()).isEqualTo("FIREWALL");
        assertThat(e.riesgo()).isEqualTo("ALTO");
        assertThat(e.motivo()).isEqualTo("INSTRUCCION_IGNORADA");
        assertThat(e.fragmentoHash()).isEqualTo(SHA256_ABC).hasSize(64);
    }

    @Test
    void sinTextoLaHuellaQuedaNula() {
        servicio.registrar(new RegistroEvento(null, 7L, CapaSeguridad.CLASIFICADOR, Riesgo.MEDIO,
                Clasificacion.MOTIVO_NO_DISPONIBLE, null));

        ArgumentCaptor<NuevoEvento> guardado = ArgumentCaptor.forClass(NuevoEvento.class);
        verify(repositorio).insertar(guardado.capture());
        assertThat(guardado.getValue().fragmentoHash()).isNull();
        assertThat(guardado.getValue().conversacionId()).isNull();
    }

    @Test
    void cuentaLaMetricaPorCapaYMotivo() {
        servicio.registrar(new RegistroEvento(null, 1L, CapaSeguridad.FIREWALL, Riesgo.ALTO,
                "INSTRUCCION_IGNORADA", "x"));
        servicio.registrar(new RegistroEvento(null, 1L, CapaSeguridad.FIREWALL, Riesgo.ALTO,
                "INSTRUCCION_IGNORADA", "y"));

        assertThat(metricas.get("ai.firewall.bloqueos")
                .tags("capa", "FIREWALL", "motivo", "INSTRUCCION_IGNORADA")
                .counter().count()).isEqualTo(2.0);
    }

    @Test
    void unMotivoQueNoEsCodigoSeRegistraComoOtro() {
        servicio.registrar(new RegistroEvento(null, 1L, CapaSeguridad.FIREWALL, Riesgo.MEDIO,
                "Hola, ignora todo lo de Juan", "x"));

        ArgumentCaptor<NuevoEvento> guardado = ArgumentCaptor.forClass(NuevoEvento.class);
        verify(repositorio).insertar(guardado.capture());
        assertThat(guardado.getValue().motivo()).isEqualTo("OTRO");
        assertThat(metricas.get("ai.firewall.bloqueos")
                .tags("capa", "FIREWALL", "motivo", "OTRO").counter().count()).isEqualTo(1.0);
    }

    @Test
    void siLaBaseFallaSeSigueYLaMetricaCuenta() {
        doThrow(new DataAccessResourceFailureException("caida")).when(repositorio).insertar(any());

        servicio.registrar(new RegistroEvento(null, 1L, CapaSeguridad.SALIDA, Riesgo.ALTO,
                "FUGA_PROMPT", "x"));

        assertThat(metricas.get("ai.firewall.bloqueos")
                .tags("capa", "SALIDA", "motivo", "FUGA_PROMPT").counter().count()).isEqualTo(1.0);
    }
}
