package com.co.eurekatic.aicontrol.agente.memoria;

import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.Asistente;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.LlamadaHerramienta;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.RespuestaHerramienta;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.ResultadoHerramienta;
import com.co.eurekatic.aicontrol.agente.memoria.MensajeMemoria.Usuario;
import com.co.eurekatic.aicontrol.agente.persistencia.MensajeStore;
import com.co.eurekatic.aicontrol.agente.persistencia.RolMensaje;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.ai.chat.messages.AssistantMessage;
import org.springframework.ai.chat.messages.Message;
import org.springframework.ai.chat.messages.ToolResponseMessage;
import org.springframework.ai.chat.messages.UserMessage;
import org.springframework.data.redis.RedisConnectionFailureException;
import org.springframework.data.redis.core.Cursor;
import org.springframework.data.redis.core.ScanOptions;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;
import tools.jackson.core.type.TypeReference;
import tools.jackson.databind.json.JsonMapper;

import java.time.Duration;
import java.util.List;
import java.util.UUID;

import static com.co.eurekatic.aicontrol.config.PropiedadesAgenteFixture.propiedades;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class RedisChatMemoryRepositoryTest {

    private static final JsonMapper JSON = JsonMapper.builder().build();
    private static final TypeReference<List<MensajeMemoria>> TIPO_LISTA = new TypeReference<>() {};
    private static final String ID = "3f2c9a1e-5b7d-4e8f-9a0b-1c2d3e4f5a6b";
    private static final String CLAVE = "ai:mem:" + ID;

    private StringRedisTemplate redis;
    private ValueOperations<String, String> valores;
    private MensajeStore mensajes;
    private RedisChatMemoryRepository repo;

    @SuppressWarnings("unchecked")
    @BeforeEach
    void setUp() {
        redis = mock(StringRedisTemplate.class);
        valores = mock(ValueOperations.class);
        mensajes = mock(MensajeStore.class);
        when(redis.opsForValue()).thenReturn(valores);
        repo = new RedisChatMemoryRepository(redis, JSON, propiedades(), mensajes);
    }

    @Test
    void saveAllReemplazaLaListaYRenuevaElTtl() {
        repo.saveAll(ID, List.of(new UserMessage("hola"), new AssistantMessage("buenas")));

        ArgumentCaptor<String> cuerpo = ArgumentCaptor.forClass(String.class);
        verify(valores).set(eq(CLAVE), cuerpo.capture(), eq(Duration.ofHours(24)));
        assertThat(cuerpo.getValue()).contains("\"USER\"", "\"hola\"", "\"ASSISTANT\"", "\"buenas\"");
    }

    @Test
    void lecturaConClaveRestauraTurnosConLlamadasYRespuestas() {
        List<MensajeMemoria> turnos = List.of(
                new Usuario("hola"),
                new Asistente("Busco.", List.of(new LlamadaHerramienta("c1", "consultar_notas", "{}"))),
                new RespuestaHerramienta(List.of(new ResultadoHerramienta("c1", "consultar_notas", "{\"ok\":true}"))));
        when(valores.get(CLAVE)).thenReturn(JSON.writerFor(TIPO_LISTA).writeValueAsString(turnos));

        List<Message> r = repo.findByConversationId(ID);

        assertThat(r).hasSize(3);
        assertThat(r.get(0)).isInstanceOf(UserMessage.class);
        assertThat(((AssistantMessage) r.get(1)).hasToolCalls()).isTrue();
        assertThat(((ToolResponseMessage) r.get(2)).getResponses()).hasSize(1);
        verifyNoInteractions(mensajes);
    }

    @Test
    void unaClaveConElFormatoAnteriorSeReconstruyeDesdeLaBase() {
        UUID id = UUID.fromString(ID);
        when(valores.get(CLAVE)).thenReturn("[{\"tipo\":\"DESCONOCIDO\",\"texto\":\"x\"}]");
        when(mensajes.listarFinales(id)).thenReturn(List.of(
                new MensajeStore.Mensaje(1L, id, 1, RolMensaje.USER, "hola", null, null, null)));

        assertThat(repo.findByConversationId(ID)).extracting(Message::getText).containsExactly("hola");
    }

    @Test
    void sinClaveSeReconstruyeDesdeLaBaseSoloConTurnosDeTexto() {
        UUID id = UUID.fromString(ID);
        when(valores.get(CLAVE)).thenReturn(null);
        when(mensajes.listarFinales(id)).thenReturn(List.of(
                new MensajeStore.Mensaje(1L, id, 1, RolMensaje.USER, "hola", null, null, null),
                new MensajeStore.Mensaje(2L, id, 2, RolMensaje.ASSISTANT, "buenas", "RESPUESTA", null, null)));

        List<Message> r = repo.findByConversationId(ID);

        assertThat(r).extracting(Message::getText).containsExactly("hola", "buenas");
        assertThat(r.get(1)).isInstanceOf(AssistantMessage.class);
    }

    @Test
    void redisCaidoEnLecturaDevuelveVacioSinConsultarLaBase() {
        when(valores.get(CLAVE)).thenThrow(new RedisConnectionFailureException("sin conexion"));

        assertThat(repo.findByConversationId(ID)).isEmpty();
        verifyNoInteractions(mensajes);
    }

    @Test
    void redisCaidoEnEscrituraNoPropagaElError() {
        doThrow(new RedisConnectionFailureException("sin conexion"))
                .when(valores).set(eq(CLAVE), anyString(), any(Duration.class));

        repo.saveAll(ID, List.of(new UserMessage("hola")));
    }

    @Test
    void findConversationIdsUsaScanYQuitaElPrefijo() {
        @SuppressWarnings("unchecked")
        Cursor<String> cursor = mock(Cursor.class);
        when(cursor.hasNext()).thenReturn(true, true, false);
        when(cursor.next()).thenReturn("ai:mem:a", "ai:mem:b");
        when(redis.scan(any(ScanOptions.class))).thenReturn(cursor);

        assertThat(repo.findConversationIds()).containsExactly("a", "b");
        verify(redis, never()).keys(anyString());
    }

    @Test
    void deleteByConversationIdBorraLaClave() {
        repo.deleteByConversationId(ID);

        verify(redis).delete(CLAVE);
    }
}
