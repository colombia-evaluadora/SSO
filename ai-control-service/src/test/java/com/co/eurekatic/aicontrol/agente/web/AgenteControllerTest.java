package com.co.eurekatic.aicontrol.agente.web;

import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;
import com.co.eurekatic.aicontrol.agente.comun.PropiedadesAgenteFixture;
import com.co.eurekatic.aicontrol.agente.nucleo.acciones.AccionesService;
import com.co.eurekatic.aicontrol.agente.nucleo.respuesta.RespuestaAgente;
import com.co.eurekatic.aicontrol.agente.nucleo.turno.AgenteService;
import com.co.eurekatic.aicontrol.agente.nucleo.turno.ConversacionesService;
import com.co.eurekatic.common.security.AuthPrincipal;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.security.core.Authentication;
import tools.jackson.databind.json.JsonMapper;

import java.time.Duration;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.doThrow;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class AgenteControllerTest {

    private final UUID conversacion = UUID.randomUUID();
    private ConversacionesService conversaciones;
    private AgenteService agente;
    private AccionesService acciones;
    private MockMvc mvc;

    @BeforeEach
    void setUp() {
        conversaciones = mock(ConversacionesService.class);
        agente = mock(AgenteService.class);
        acciones = mock(AccionesService.class);
        mvc = MockMvcBuilders.standaloneSetup(new AgenteController(conversaciones, agente, acciones,
                        PropiedadesAgenteFixture.propiedades(), JsonMapper.builder().build()))
                .setControllerAdvice(new ManejadorErrores())
                .build();
    }

    @Test
    void creaUnaConversacionYDevuelveSuId() throws Exception {
        when(conversaciones.crear(any())).thenReturn(conversacion);

        mvc.perform(post("/ai/agente/conversaciones").principal(usuario()))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.conversationId").value(conversacion.toString()));
    }

    @Test
    void unaConversacionAjenaResponde404() throws Exception {
        when(conversaciones.detalle(eq(conversacion), any()))
                .thenThrow(new ErrorAgente.ConversacionNoEncontrada());

        mvc.perform(get("/ai/agente/conversaciones/" + conversacion).principal(usuario()))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.mensaje").value("La conversación no existe."));
    }

    @Test
    void archivarResponde204() throws Exception {
        mvc.perform(put("/ai/agente/conversaciones/" + conversacion + "/archivar").principal(usuario()))
                .andExpect(status().isNoContent());
    }

    @Test
    void archivarUnaAjenaResponde404() throws Exception {
        doThrow(new ErrorAgente.ConversacionNoEncontrada()).when(conversaciones).archivar(any(), any());

        mvc.perform(put("/ai/agente/conversaciones/" + conversacion + "/archivar").principal(usuario()))
                .andExpect(status().isNotFound());
    }

    @Test
    void unMensajeDevuelveLaRespuestaConSuTipo() throws Exception {
        when(agente.procesar(eq(conversacion), any(), eq("hola"), eq(""))).thenReturn(new RespuestaAgente.Respuesta("¡Hola!"));

        mvc.perform(post("/ai/agente/conversaciones/" + conversacion + "/mensajes")
                        .principal(usuario())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"texto\":\"hola\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.tipo").value("RESPUESTA"))
                .andExpect(jsonPath("$.texto").value("¡Hola!"))
                .andExpect(jsonPath("$.faltantes").doesNotExist());
    }

    @Test
    void elLimitePorUsuarioResponde429ConRetryAfter() throws Exception {
        when(agente.procesar(any(), any(), anyString(), anyString()))
                .thenThrow(new ErrorAgente.LimiteExcedido(Duration.ofSeconds(60)));

        mvc.perform(post("/ai/agente/conversaciones/" + conversacion + "/mensajes")
                        .principal(usuario())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"texto\":\"hola\"}"))
                .andExpect(status().isTooManyRequests())
                .andExpect(header().string("Retry-After", "60"));
    }

    @Test
    void unTextoVacioEsUnaPeticionInvalida() throws Exception {
        mvc.perform(post("/ai/agente/conversaciones/" + conversacion + "/mensajes")
                        .principal(usuario())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"texto\":\"  \"}"))
                .andExpect(status().isBadRequest());
    }

    @Test
    void unaSesionSinIdentidadResponde403() throws Exception {
        mvc.perform(post("/ai/agente/conversaciones"))
                .andExpect(status().isForbidden());
    }

    private static Authentication usuario() {
        AuthPrincipal principal = new AuthPrincipal("docente@colegio.test", 7L, Set.of("DOCENTE"), "access", null, null);
        return new UsernamePasswordAuthenticationToken(principal, "token-de-prueba", List.of());
    }
}
