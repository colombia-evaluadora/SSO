package com.co.eurekatic.aicontrol.agente.catalogo.invocacion;

import com.co.eurekatic.aicontrol.agente.catalogo.CatalogoFixture;
import com.co.eurekatic.aicontrol.agente.catalogo.dominio.HerramientaDef;
import com.co.eurekatic.aicontrol.agente.comun.PropiedadesAgenteFixture;
import com.co.eurekatic.aicontrol.agente.persistencia.herramienta.EstadoInvocacion;
import com.co.eurekatic.aicontrol.agente.persistencia.herramienta.ToolInvocacionStore;
import com.co.eurekatic.aicontrol.client.QueryServiceClient;
import com.co.eurekatic.aicontrol.client.RespuestaQuery;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.http.HttpMethod;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class InvocadorHerramientasTest {

    private static final String CONV = "conv-1";

    private QueryServiceClient qs;
    private RegistroIdsEnMemoria registro;
    private ToolInvocacionStore almacen;
    private InvocadorHerramientas invocador;
    private List<ResultadoHerramienta.RequiereConfirmacion> propuestas;

    private final HerramientaDef editar = CatalogoFixture.editarFuncionarioDef();
    private final HerramientaDef listar = CatalogoFixture.actividadesMiasDef();

    @BeforeEach
    void preparar() {
        qs = mock(QueryServiceClient.class);
        registro = new RegistroIdsEnMemoria();
        almacen = mock(ToolInvocacionStore.class);
        invocador = new InvocadorHerramientas(qs, new VerificadorIds(registro), registro, almacen,
                PropiedadesAgenteFixture.propiedades());
        propuestas = new ArrayList<>();
    }

    private ContextoInvocacion contexto(String textoUsuario) {
        return new ContextoInvocacion(42L, "token-usuario", CONV, 7L, textoUsuario, propuestas::add);
    }

    private ToolInvocacionStore.NuevaInvocacion auditada() {
        ArgumentCaptor<ToolInvocacionStore.NuevaInvocacion> captor =
                ArgumentCaptor.forClass(ToolInvocacionStore.NuevaInvocacion.class);
        verify(almacen).insertar(captor.capture());
        return captor.getValue();
    }

    @Test
    void lecturaOkDevuelveDatosRegistraLosIdsYAuditaSinValores() {
        when(qs.invocar(any(), anyString(), anyMap(), anyMap(), eq("token-usuario"))).thenReturn(
                new RespuestaQuery.Exito(List.of(Map.of("id", 5, "titulo", "Secreto del alumno"))));

        ResultadoHerramienta r = invocador.invocar(listar, Map.of("size", 5), contexto("lista"));

        assertThat(r).isInstanceOf(ResultadoHerramienta.Datos.class);
        assertThat(((ResultadoHerramienta.Datos) r).filas()).hasSize(1);
        assertThat(registro.contiene(CONV, "5")).isTrue();
        ToolInvocacionStore.NuevaInvocacion inv = auditada();
        assertThat(inv.estado()).isEqualTo(EstadoInvocacion.OK);
        assertThat(inv.herramientaId()).isEqualTo(listar.id());
        assertThat(inv.argumentosJson()).isEqualTo("{\"claves\":[\"size\"],\"descartadas\":0}");
        assertThat(inv.argumentosJson()).doesNotContain("Secreto");
    }

    @Test
    void lasColumnasSensiblesNoLlegan_AlResultado_PeroLosIdsSiSeRegistran() {
        when(qs.invocar(any(), anyString(), anyMap(), anyMap(), anyString())).thenReturn(
                new RespuestaQuery.Exito(List.of(Map.of("id", 5, "email", "a@b.co", "nombre", "Ana"))));

        ResultadoHerramienta r = invocador.invocar(listar, Map.of(), contexto("lista"));

        assertThat(((ResultadoHerramienta.Datos) r).filas().get(0)).containsOnlyKeys("id", "nombre");
        assertThat(registro.contiene(CONV, "5")).isTrue();
    }

    @Test
    void elGateDelQueryServiceSeTraduceParaElModelo() {
        when(qs.invocar(any(), anyString(), anyMap(), anyMap(), anyString())).thenReturn(
                new RespuestaQuery.ErrorCliente(403, "Tu rol no permite ver esto"));

        ResultadoHerramienta r = invocador.invocar(listar, Map.of("size", 5), contexto("lista"));

        assertThat(r).isEqualTo(new ResultadoHerramienta.ErrorParaModelo(
                "No tienes permiso para esta accion: Tu rol no permite ver esto"));
        ToolInvocacionStore.NuevaInvocacion inv = auditada();
        assertThat(inv.estado()).isEqualTo(EstadoInvocacion.ERROR);
        assertThat(inv.httpStatus()).isEqualTo(403);
    }

    @Test
    void unFalloDelServidorNoRevelaSuDetalle() {
        when(qs.invocar(any(), anyString(), anyMap(), anyMap(), anyString())).thenReturn(
                new RespuestaQuery.ErrorServidor());

        ResultadoHerramienta r = invocador.invocar(listar, Map.of(), contexto("lista"));

        assertThat(r).isInstanceOf(ResultadoHerramienta.ErrorParaModelo.class);
        assertThat(((ResultadoHerramienta.ErrorParaModelo) r).texto()).contains("No reintentes");
        assertThat(auditada().estado()).isEqualTo(EstadoInvocacion.ERROR);
    }

    @Test
    void escrituraNuncaLlamaAlQueryServiceYPropone() {
        registro.registrar(CONV, List.of(Map.of("id", 12)));

        ResultadoHerramienta r = invocador.invocar(editar,
                Map.of("id", 12, "person_email", "a@b.co"), contexto("cambia el correo"));

        assertThat(r).isInstanceOf(ResultadoHerramienta.RequiereConfirmacion.class);
        assertThat(propuestas).hasSize(1);
        verify(qs, never()).invocar(any(), anyString(), anyMap(), anyMap(), anyString());
        assertThat(auditada().estado()).isEqualTo(EstadoInvocacion.PENDIENTE);
    }

    @Test
    void unIdQueNoSalioDeUnResultadoPrevioSeRechazaConLaPista() {
        ResultadoHerramienta r = invocador.invocar(editar,
                Map.of("id", 99, "person_email", "a@b.co"), contexto("cambia el correo"));

        assertThat(r).isInstanceOf(ResultadoHerramienta.ErrorParaModelo.class);
        assertThat(((ResultadoHerramienta.ErrorParaModelo) r).texto()).contains("funcionarios_listar");
        assertThat(propuestas).isEmpty();
        assertThat(auditada().estado()).isEqualTo(EstadoInvocacion.RECHAZADA);
    }

    @Test
    void unIdQueElUsuarioEscribioLiteralmenteSeAcepta() {
        ResultadoHerramienta r = invocador.invocar(editar,
                Map.of("id", 99, "person_email", "a@b.co"), contexto("cambia el correo del 99"));

        assertThat(r).isInstanceOf(ResultadoHerramienta.RequiereConfirmacion.class);
    }

    @Test
    void unArgumentoMalTipadoSeRechazaSinLlamarAlQueryService() {
        ResultadoHerramienta r = invocador.invocar(editar, Map.of("id", "12"), contexto("x"));

        assertThat(((ResultadoHerramienta.ErrorParaModelo) r).texto()).contains("debe ser un entero");
        verify(qs, never()).invocar(any(), anyString(), anyMap(), anyMap(), anyString());
        assertThat(auditada().estado()).isEqualTo(EstadoInvocacion.RECHAZADA);
    }

    @Test
    void unResultadoLargoSeCortaYSeMarca() {
        List<Map<String, Object>> filas = new ArrayList<>();
        for (int i = 0; i < 60; i++) {
            filas.add(Map.of("id", i));
        }
        when(qs.invocar(any(), anyString(), anyMap(), anyMap(), anyString())).thenReturn(
                new RespuestaQuery.Exito(filas));

        ResultadoHerramienta r = invocador.invocar(listar, Map.of(), contexto("lista"));

        ResultadoHerramienta.Datos datos = (ResultadoHerramienta.Datos) r;
        assertThat(datos.filas()).hasSize(50);
        assertThat(datos.truncado()).isTrue();
        assertThat(registro.contiene(CONV, "49")).isTrue();
        assertThat(registro.contiene(CONV, "50")).isFalse();
    }

    @Test
    void siLaAuditoriaFallaLaHerramientaSigueRespondiendo() {
        when(qs.invocar(any(), anyString(), anyMap(), anyMap(), anyString())).thenReturn(
                new RespuestaQuery.Exito(List.of()));
        doThrow(new DataAccessResourceFailureException("caido")).when(almacen).insertar(any());

        ResultadoHerramienta r = invocador.invocar(listar, Map.of(), contexto("lista"));

        assertThat(r).isInstanceOf(ResultadoHerramienta.Datos.class);
    }

    @Test
    void laRutaSeEnvianConElMetodoDeLaHerramienta() {
        when(qs.invocar(any(), anyString(), anyMap(), anyMap(), anyString())).thenReturn(
                new RespuestaQuery.Exito(List.of()));

        invocador.invocar(listar, Map.of("size", 5), contexto("lista"));

        verify(qs).invocar(eq(HttpMethod.GET), eq("/planeador/actividades/mias"), eq(Map.of("SIZE", "5")),
                eq(Map.of()), eq("token-usuario"));
    }
}
