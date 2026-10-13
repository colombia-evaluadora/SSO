package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.agente.catalogo.CatalogoFixture;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.TipoHerramienta;
import com.co.eurekatic.aicontrol.agente.comun.PropiedadesAgenteFixture;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.ai.chat.model.ToolContext;
import org.springframework.ai.tool.ToolCallback;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class FabricaToolCallbacksTest {

    private final InvocadorHerramientas invocador = mock(InvocadorHerramientas.class);
    private final FabricaToolCallbacks fabrica = new FabricaToolCallbacks(invocador,
            new FormateadorResultado(PropiedadesAgenteFixture.propiedades()));

    @Test
    void elCallbackExponeElEsquemaYDecodificaLosArgumentosDelModelo() {
        HerramientaDef editar = CatalogoFixture.editarFuncionarioDef();
        when(invocador.invocar(eq(editar), any(), any())).thenReturn(
                new ResultadoHerramienta.ErrorParaModelo("falta el id"));
        ToolCallback callback = fabrica.crear(editar);
        ContextoInvocacion ctx = new ContextoInvocacion(42L, "token", "conv-1", 7L, "x", r -> { });

        String salida = callback.call("{\"id\": 12, \"person_email\": \"a@b.co\"}", new ToolContext(ctx.comoMapa()));

        assertThat(salida).isEqualTo("falta el id");
        assertThat(callback.getToolDefinition().name()).isEqualTo("editar_funcionario");
        assertThat(callback.getToolDefinition().inputSchema()).contains("\"additionalProperties\":false");
        ArgumentCaptor<Map<String, Object>> args = ArgumentCaptor.forClass(Map.class);
        verify(invocador).invocar(eq(editar), args.capture(), eq(ctx));
        assertThat(((Number) args.getValue().get("id")).longValue()).isEqualTo(12L);
        assertThat(args.getValue().get("person_email")).isEqualTo("a@b.co");
    }

    @Test
    void unaLecturaNoEsDevolucionDirecta() {
        ToolCallback callback = fabrica.crear(CatalogoFixture.actividadesMiasDef());

        assertThat(callback.getToolMetadata().returnDirect()).isFalse();
    }

    @Test
    void soloSeFabricanCallbacksDeDatos() {
        HerramientaDef control = new HerramientaDef(401L, "buscar_pantalla", TipoHerramienta.CONTROL, "d", List.of(),
                false, List.of(), 1, Optional.empty(), Optional.empty(), Set.of());
        List<HerramientaDef> todas = new ArrayList<>(List.of(control, CatalogoFixture.actividadesMiasDef()));

        assertThat(fabrica.crearTodas(todas)).hasSize(1);
        assertThatThrownBy(() -> fabrica.crear(control)).isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void sinContextoEnLaLlamadaFallaDeFormaExplicita() {
        ToolCallback callback = fabrica.crear(CatalogoFixture.actividadesMiasDef());

        assertThatThrownBy(() -> callback.call("{}", null)).hasMessageContaining("ContextoInvocacion");
    }
}
