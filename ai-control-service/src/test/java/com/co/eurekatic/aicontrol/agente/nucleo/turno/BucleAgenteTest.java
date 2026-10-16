package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ArgumentosCanonicos;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ContextoInvocacion;
import com.co.eurekatic.aicontrol.agente.catalogo.invocacion.ResultadoHerramienta.RequiereConfirmacion;
import com.co.eurekatic.aicontrol.agente.comun.PropiedadesAgenteFixture;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.nucleo.TurnoContexto;
import com.co.eurekatic.aicontrol.agente.nucleo.control.PedirDatosFaltantesHerramienta;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.llm.ModeloInvoker;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.UserMessage;
import org.springframework.ai.chat.model.ChatResponse;
import org.springframework.ai.chat.model.Generation;
import org.springframework.ai.model.tool.DefaultToolCallingManager;
import org.springframework.ai.tool.ToolCallback;
import org.springframework.ai.tool.function.FunctionToolCallback;
import org.springframework.core.ParameterizedTypeReference;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Answers.RETURNS_SELF;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.withSettings;

class BucleAgenteTest {

    private static final UsuarioAgente USUARIO = new UsuarioAgente(7L, Set.of("DOCENTE"), "token");
    private static final HerramientaDef ESCRITURA = new HerramientaDef(42L, "crear_funcion", TipoHerramienta.ESCRITURA,
            "Crear funcionario", List.of(), true, List.of(), 1, Optional.of("FUNCIONARIOS"), Optional.empty(), Set.of());
    private static final String ESQUEMA_VACIO = "{\"type\":\"object\",\"properties\":{}}";

    private ChatClient razonador;
    private ChatClient.CallResponseSpec llamada;
    private int llamadasAlModelo;
    private BucleAgente bucle;

    @BeforeEach
    void setUp() {
        razonador = mock(ChatClient.class);
        ChatClient.ChatClientRequestSpec req = mock(ChatClient.ChatClientRequestSpec.class, withSettings().defaultAnswer(RETURNS_SELF));
        llamada = mock(ChatClient.CallResponseSpec.class);
        when(razonador.prompt()).thenReturn(req);
        when(req.call()).thenReturn(llamada);
        ModeloInvoker invocador = mock(ModeloInvoker.class);
        when(invocador.invocar(any())).thenAnswer(i -> {
            llamadasAlModelo++;
            return ((Supplier<?>) i.getArgument(0)).get();
        });
        bucle = new BucleAgente(razonador, invocador,
                DefaultToolCallingManager.builder().build(), PropiedadesAgenteFixture.propiedades());
    }

    @Test
    void sinHerramientasDevuelveElTextoDelModelo() {
        when(llamada.chatResponse()).thenReturn(texto("Hola, ¿en qué te ayudo?"));

        ResultadoBucle resultado = bucle.ejecutar(entrada(new TurnoContexto(List.of()), List.of()));

        assertThat(resultado).isInstanceOfSatisfying(ResultadoBucle.Final.class,
                f -> assertThat(f.respuesta().texto()).isEqualTo("Hola, ¿en qué te ayudo?"));
        assertThat(llamadasAlModelo).isEqualTo(1);
    }

    @Test
    void unaLecturaSeEjecutaYLuegoElModeloRespondeConElResultado() {
        ToolCallback lectura = FunctionToolCallback.builder("lista_sedes",
                        (Map<String, Object> args, org.springframework.ai.chat.model.ToolContext ctx) -> "3 sedes")
                .description("Lista sedes").inputSchema(ESQUEMA_VACIO)
                .inputType(new ParameterizedTypeReference<Map<String, Object>>() {}).build();
        when(llamada.chatResponse()).thenReturn(llamadas("lista_sedes"), texto("Hay 3 sedes."));

        ResultadoBucle resultado = bucle.ejecutar(entrada(new TurnoContexto(List.of()), List.of(lectura)));

        assertThat(resultado).isInstanceOfSatisfying(ResultadoBucle.Final.class,
                f -> assertThat(f.respuesta().texto()).isEqualTo("Hay 3 sedes."));
        assertThat(llamadasAlModelo).isEqualTo(2);
    }

    @Test
    void unaEscrituraSeProponeSinEjecutarse() {
        boolean[] ejecutada = {false};
        ToolCallback escritura = FunctionToolCallback.builder("crear_funcion",
                        (Map<String, Object> args, org.springframework.ai.chat.model.ToolContext ctx) -> {
                            ejecutada[0] = true;
                            ContextoInvocacion.de(ctx).alProponer().accept(new RequiereConfirmacion(
                                    new ArgumentosCanonicos(Map.of("BODY.NOMBRE", "Ana")), "Crear a Ana"));
                            return "Accion preparada";
                        })
                .description("Crea").inputSchema(ESQUEMA_VACIO)
                .inputType(new ParameterizedTypeReference<Map<String, Object>>() {}).build();
        when(llamada.chatResponse()).thenReturn(llamadas("crear_funcion"));

        ResultadoBucle resultado = bucle.ejecutar(entrada(new TurnoContexto(List.of(ESCRITURA)), List.of(escritura)));

        assertThat(resultado).isInstanceOfSatisfying(ResultadoBucle.Propuesta.class, p -> {
            assertThat(p.herramienta().codigo()).isEqualTo("crear_funcion");
            assertThat(p.confirmacion().resumen()).isEqualTo("Crear a Ana");
        });
        assertThat(ejecutada[0]).isTrue();
        assertThat(llamadasAlModelo).isEqualTo(1);
    }

    @Test
    void pedirDatosFaltantesTerminaElTurnoConLaPregunta() {
        ToolCallback pedir = new PedirDatosFaltantesHerramienta().callbacks().get(0);
        when(llamada.chatResponse()).thenReturn(llamadasCon("pedir_datos_faltantes",
                "{\"faltantes\":[{\"campo\":\"jornada\",\"pregunta\":\"¿Jornada?\"}]}"));

        ResultadoBucle resultado = bucle.ejecutar(entrada(new TurnoContexto(List.of()), List.of(pedir)));

        assertThat(resultado).isInstanceOfSatisfying(ResultadoBucle.Final.class,
                f -> assertThat(f.respuesta()).isInstanceOf(RespuestaAgente.Pregunta.class));
        assertThat(llamadasAlModelo).isEqualTo(1);
    }

    @Test
    void alSuperarElPresupuestoDeHerramientasSeCorta() {
        ToolCallback lectura = FunctionToolCallback.builder("lista_sedes",
                        (Map<String, Object> args, org.springframework.ai.chat.model.ToolContext ctx) -> "ok")
                .description("Lista").inputSchema(ESQUEMA_VACIO)
                .inputType(new ParameterizedTypeReference<Map<String, Object>>() {}).build();
        when(llamada.chatResponse()).thenReturn(llamadas("lista_sedes"));

        ResultadoBucle resultado = bucle.ejecutar(entrada(new TurnoContexto(List.of()), List.of(lectura)));

        assertThat(resultado).isInstanceOfSatisfying(ResultadoBucle.Final.class,
                f -> assertThat(f.respuesta().texto()).isEqualTo(BucleAgente.MENSAJE_LIMITE));
        // Cinco llamadas por herramienta: la sexta ronda no llega a ejecutarse.
        assertThat(llamadasAlModelo).isEqualTo(6);
    }

    @Test
    void unTextoObjetadoVuelveAlModeloUnaSolaVez() {
        when(llamada.chatResponse()).thenReturn(texto("Listo, rellené el nombre."), texto("Listo, rellené el nombre."));
        BucleAgente.Entrada base = entrada(new TurnoContexto(List.of()), List.of());
        BucleAgente.Entrada conGuarda = new BucleAgente.Entrada(base.usuario(), base.conversacionId(), base.mensajeId(),
                base.textoUsuario(), base.mensajes(), base.callbacks(), base.contexto(), GuardaDeAfirmaciones::objecion);

        ResultadoBucle resultado = bucle.ejecutar(conGuarda);

        // La segunda respuesta ya no se objeta: llega al turno, que la sustituye con la guarda.
        assertThat(resultado).isInstanceOfSatisfying(ResultadoBucle.Final.class,
                f -> assertThat(f.respuesta().texto()).isEqualTo("Listo, rellené el nombre."));
        assertThat(llamadasAlModelo).isEqualTo(2);
    }

    @Test
    void unaHerramientaNoOfrecidaSeAvisaUnaVezYElModeloPuedeResponder() {
        when(llamada.chatResponse()).thenReturn(llamadas("calificar_estudiante_actividad"), texto("Te falta el peso."));

        ResultadoBucle resultado = bucle.ejecutar(entrada(new TurnoContexto(List.of()), List.of()));

        assertThat(resultado).isInstanceOfSatisfying(ResultadoBucle.Final.class,
                f -> assertThat(f.respuesta().texto()).isEqualTo("Te falta el peso."));
        assertThat(llamadasAlModelo).isEqualTo(2);
    }

    @Test
    void siInsisteEnLaHerramientaNoOfrecidaElTurnoSeCorta() {
        when(llamada.chatResponse()).thenReturn(llamadas("calificar_estudiante_actividad"),
                llamadas("calificar_estudiante_actividad"));

        ResultadoBucle resultado = bucle.ejecutar(entrada(new TurnoContexto(List.of()), List.of()));

        assertThat(resultado).isInstanceOfSatisfying(ResultadoBucle.Final.class,
                f -> assertThat(f.respuesta().texto()).isEqualTo(BucleAgente.MENSAJE_VACIO));
    }

    @Test
    void sinObjecionNoHayReintento() {
        when(llamada.chatResponse()).thenReturn(texto("Hay 3 sedes."));
        BucleAgente.Entrada base = entrada(new TurnoContexto(List.of()), List.of());

        bucle.ejecutar(new BucleAgente.Entrada(base.usuario(), base.conversacionId(), base.mensajeId(),
                base.textoUsuario(), base.mensajes(), base.callbacks(), base.contexto(), GuardaDeAfirmaciones::objecion));

        assertThat(llamadasAlModelo).isEqualTo(1);
    }

    private BucleAgente.Entrada entrada(TurnoContexto turno, List<ToolCallback> callbacks) {
        List<Message> mensajes = List.of(new UserMessage("hola"));
        return new BucleAgente.Entrada(USUARIO, UUID.randomUUID(), 1L, "hola", mensajes, callbacks, turno);
    }

    private static ChatResponse texto(String texto) {
        return new ChatResponse(List.of(new Generation(AssistantMessage.builder().content(texto).build())));
    }

    private static ChatResponse llamadas(String herramienta) {
        return llamadasCon(herramienta, "{}");
    }

    private static ChatResponse llamadasCon(String herramienta, String argumentos) {
        AssistantMessage salida = AssistantMessage.builder()
                .content("")
                .toolCalls(List.of(new AssistantMessage.ToolCall("id-" + herramienta, "function", herramienta, argumentos)))
                .build();
        return new ChatResponse(List.of(new Generation(salida)));
    }
}
