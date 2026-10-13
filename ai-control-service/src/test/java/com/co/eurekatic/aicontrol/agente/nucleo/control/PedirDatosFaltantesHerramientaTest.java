package com.co.eurekatic.aicontrol.agente.nucleo.control;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.nucleo.TurnoContexto;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import org.junit.jupiter.api.Test;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.tool.ToolCallback;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class PedirDatosFaltantesHerramientaTest {

    private static final String ARGUMENTOS = """
            {"faltantes":[{"campo":"jornada","pregunta":"¿En qué jornada?","opciones":["MAÑANA","TARDE"]}],
             "borrador":{"nombres":"Ana","sede":null}}
            """;

    @Test
    void registraLaPreguntaComoRespuestaDirectaYTerminaElTurno() {
        TurnoContexto turno = new TurnoContexto(List.of());
        ToolCallback pedir = new PedirDatosFaltantesHerramienta().callbacks().get(0);

        String acuse = pedir.call(ARGUMENTOS, new ToolContext(Map.of(TurnoContexto.CLAVE, turno)));

        assertThat(acuse).isEqualTo(PedirDatosFaltantesHerramienta.ACUSE);
        assertThat(turno.directa()).containsInstanceOf(RespuestaAgente.Pregunta.class);
        RespuestaAgente.Pregunta pregunta = (RespuestaAgente.Pregunta) turno.directa().orElseThrow();
        assertThat(pregunta.faltantes().get(0).campo()).isEqualTo("jornada");
        assertThat(pregunta.faltantes().get(0).opciones()).containsExactly("MAÑANA", "TARDE");
        assertThat(pregunta.borrador()).containsOnlyKeys("nombres");
    }

    @Test
    void sinFaltantesValidosNoTerminaElTurno() {
        TurnoContexto turno = new TurnoContexto(List.of());
        ToolCallback pedir = new PedirDatosFaltantesHerramienta().callbacks().get(0);

        String respuesta = pedir.call("{\"faltantes\":[{\"campo\":\" \",\"pregunta\":\"x\"}]}",
                new ToolContext(Map.of(TurnoContexto.CLAVE, turno)));

        assertThat(respuesta).isEqualTo(PedirDatosFaltantesHerramienta.ERROR);
        assertThat(turno.directa()).isEmpty();
    }

    @Test
    void lasOpcionesNoTextualesSeDescartan() {
        Optional<RespuestaAgente.Pregunta> pregunta = PedirDatosFaltantesHerramienta.leer(Map.of(
                "faltantes", List.of(Map.of("campo", "sede", "pregunta", "¿Cuál?", "opciones", List.of(1, "A")))));

        assertThat(pregunta).isPresent();
        assertThat(pregunta.get().faltantes().get(0).opciones()).containsExactly("A");
    }

    @Test
    void sinFaltantesNoHayPregunta() {
        assertThat(PedirDatosFaltantesHerramienta.leer(Map.of())).isEmpty();
        assertThat(PedirDatosFaltantesHerramienta.leer(Map.of("faltantes", List.of()))).isEmpty();
    }

    @Test
    void esquemaDeAccionDevuelveElSchemaDeUnaHerramientaDelTurno() {
        HerramientaDef crear = new HerramientaDef(7L, "crear_funcion", TipoHerramienta.ESCRITURA, "Crear funcionario",
                List.of(), true, List.of(), 1, Optional.of("FUNCIONARIOS"), Optional.empty(), Set.of());
        TurnoContexto turno = new TurnoContexto(List.of(crear));
        ToolCallback esquema = new EsquemaDeAccionHerramienta().callbacks().get(0);

        String resultado = esquema.call("{\"codigo\":\"crear_funcion\"}", new ToolContext(Map.of(TurnoContexto.CLAVE, turno)));
        String ajena = esquema.call("{\"codigo\":\"borrar_todo\"}", new ToolContext(Map.of(TurnoContexto.CLAVE, turno)));

        assertThat(resultado).contains("\"additionalProperties\":false");
        assertThat(ajena).isEqualTo(EsquemaDeAccionHerramienta.NO_DISPONIBLE);
    }
}
