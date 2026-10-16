package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ResultadoHerramienta;
import com.co.eurekatic.aicontrol.agente.nucleo.TurnoContexto;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.persistencia.analitica.ConsultaAnaliticaStore;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class PresentadorAnaliticaTest {

    private final ConsultaAnaliticaStore consultas = mock(ConsultaAnaliticaStore.class);
    private final PresentadorAnalitica presentador = new PresentadorAnalitica(consultas);

    @Test
    void unaTablaDeAnaliticaConvierteElTextoFinalEnDatosYQuedaRegistrada() {
        TurnoContexto turno = new TurnoContexto(List.of());
        turno.alObtener(herramienta(TipoHerramienta.ANALITICA), new ResultadoHerramienta.Datos(
                List.of(fila("estado", "PENDIENTE", "total", 3), fila("estado", "CALIFICADA", "total", 5)), true));

        RespuestaAgente respuesta = presentador.presentar(new RespuestaAgente.Respuesta("Tienes 8 actividades."), turno, 11L);

        assertThat(respuesta).isInstanceOfSatisfying(RespuestaAgente.Datos.class, datos -> {
            assertThat(datos.texto()).isEqualTo("Tienes 8 actividades.");
            assertThat(datos.columnas()).containsExactly("estado", "total");
            assertThat(datos.filas()).hasSize(2);
        });
        ArgumentCaptor<ConsultaAnaliticaStore.NuevaConsulta> consulta =
                ArgumentCaptor.forClass(ConsultaAnaliticaStore.NuevaConsulta.class);
        verify(consultas).insertar(consulta.capture());
        assertThat(consulta.getValue().nivel()).isEqualTo(1);
        assertThat(consulta.getValue().mensajeId()).isEqualTo(11L);
        assertThat(consulta.getValue().motivo()).isEqualTo(PresentadorAnalitica.MOTIVO_TRUNCADA);
    }

    @Test
    void unaLecturaNormalNoEsAnalitica() {
        TurnoContexto turno = new TurnoContexto(List.of());
        turno.alObtener(herramienta(TipoHerramienta.LECTURA),
                new ResultadoHerramienta.Datos(List.of(fila("id", 1, "nombre", "Sede A")), false));

        RespuestaAgente respuesta = presentador.presentar(new RespuestaAgente.Respuesta("Una sede."), turno, 11L);

        assertThat(respuesta).isInstanceOf(RespuestaAgente.Respuesta.class);
        verify(consultas, never()).insertar(any());
    }

    @Test
    void siNoSePuedeRegistrarLaRespuestaSaleIgual() {
        when(consultas.insertar(any())).thenThrow(new IllegalStateException("base caida"));
        TurnoContexto turno = new TurnoContexto(List.of());
        turno.alObtener(herramienta(TipoHerramienta.ANALITICA),
                new ResultadoHerramienta.Datos(List.of(fila("total", 1, "x", 2)), false));

        assertThat(presentador.presentar(new RespuestaAgente.Respuesta("ok"), turno, 1L))
                .isInstanceOf(RespuestaAgente.Datos.class);
    }

    private static HerramientaDef herramienta(TipoHerramienta tipo) {
        HerramientaDef herramienta = mock(HerramientaDef.class);
        when(herramienta.tipo()).thenReturn(tipo);
        when(herramienta.codigo()).thenReturn("planeador_estadisticas");
        return herramienta;
    }

    private static Map<String, Object> fila(String k1, Object v1, String k2, Object v2) {
        Map<String, Object> fila = new LinkedHashMap<>();
        fila.put(k1, v1);
        fila.put(k2, v2);
        return fila;
    }
}
