package com.co.eurekatic.aicontrol.agente.nucleo.intencion;

import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.seguridad.Riesgo;
import com.co.eurekatic.aicontrol.llm.ModeloInvoker;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.ai.chat.client.ChatClient;
import org.springframework.core.io.ClassPathResource;
import tools.jackson.databind.json.JsonMapper;

import java.util.function.Supplier;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class RouterIntencionTest {

    private static final JsonMapper JSON = JsonMapper.builder().build();

    private ChatClient chat;
    private ChatClient.ChatClientRequestSpec req;
    private ChatClient.CallResponseSpec llamada;
    private RouterIntencion router;

    @BeforeEach
    void setUp() {
        chat = mock(ChatClient.class);
        req = mock(ChatClient.ChatClientRequestSpec.class);
        llamada = mock(ChatClient.CallResponseSpec.class);
        ModeloInvoker invoker = mock(ModeloInvoker.class);
        when(chat.prompt()).thenReturn(req);
        when(req.system(org.mockito.ArgumentMatchers.anyString())).thenReturn(req);
        when(req.user(org.mockito.ArgumentMatchers.anyString())).thenReturn(req);
        when(req.call()).thenReturn(llamada);
        when(invoker.invocar(any())).thenAnswer(i -> ((Supplier<?>) i.getArgument(0)).get());
        router = new RouterIntencion(chat, invoker, JSON, new ClassPathResource("prompts/agente-router.st"));
    }

    @Test
    void leeTipoAccionYConfianzaDeLaSalidaDelModelo() {
        when(llamada.content()).thenReturn("Claro: {\"tipo\": \"ACCION\", \"accion\": \"crear_funcionario\", \"confianza\": 0.92}");

        Intencion intencion = router.clasificar("crea un funcionario", Riesgo.BAJO);

        assertThat(intencion.tipo()).isEqualTo(TipoIntencion.ACCION);
        assertThat(intencion.accion()).isEqualTo("CREAR_FUNCIONARIO");
        assertThat(intencion.confianza()).isEqualTo(0.92);
        assertThat(intencion.riesgo()).isEqualTo(Riesgo.BAJO);
    }

    @Test
    void accionNulaOInvalidaSeDescarta() {
        when(llamada.content()).thenReturn("{\"tipo\": \"CONSULTA\", \"accion\": \"null\", \"confianza\": 0.5}");
        assertThat(router.clasificar("lista sedes", Riesgo.BAJO).accion()).isEmpty();

        when(llamada.content()).thenReturn("{\"tipo\": \"CONSULTA\", \"accion\": \"borra; drop\", \"confianza\": 0.5}");
        assertThat(router.clasificar("lista sedes", Riesgo.BAJO).accion()).isEmpty();
    }

    @Test
    void falloDelModeloDevuelveConsultaDeRiesgoMedio() {
        when(llamada.content()).thenThrow(new IllegalStateException("proveedor roto"));

        Intencion intencion = router.clasificar("crea algo", Riesgo.BAJO);

        assertThat(intencion.tipo()).isEqualTo(TipoIntencion.CONSULTA);
        assertThat(intencion.riesgo()).isEqualTo(Riesgo.MEDIO);
    }

    @Test
    void salidaIlegibleDevuelveConsultaDeRiesgoMedio() {
        when(llamada.content()).thenReturn("no es json");

        assertThat(router.clasificar("crea algo", Riesgo.BAJO).tipo()).isEqualTo(TipoIntencion.CONSULTA);
    }

    @Test
    void tipoDesconocidoEsSalidaIlegible() {
        when(llamada.content()).thenReturn("{\"tipo\": \"HACKEAR\", \"confianza\": 1}");

        Intencion intencion = router.clasificar("hola", Riesgo.BAJO);

        assertThat(intencion.tipo()).isEqualTo(TipoIntencion.CONSULTA);
        assertThat(intencion.riesgo()).isEqualTo(Riesgo.MEDIO);
    }

    @Test
    void elRiesgoDeLaEntradaAltaSeHereda() {
        when(llamada.content()).thenReturn("{\"tipo\": \"CHARLA\", \"accion\": null, \"confianza\": 0.4}");

        assertThat(router.clasificar("hola", Riesgo.MEDIO).riesgo()).isEqualTo(Riesgo.MEDIO);
    }

    @Test
    void charlaNoTieneHerramientas() {
        assertThat(TipoIntencion.CHARLA.herramientasPermitidas()).isEmpty();
        assertThat(TipoIntencion.ACCION.herramientasPermitidas())
                .containsExactlyInAnyOrder(TipoHerramienta.LECTURA, TipoHerramienta.ESCRITURA, TipoHerramienta.CONTROL);
        assertThat(TipoIntencion.CONSULTA.herramientasPermitidas())
                .doesNotContain(TipoHerramienta.ESCRITURA, TipoHerramienta.ANALITICA);
    }
}
