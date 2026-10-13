package com.co.eurekatic.aicontrol.agente.nucleo.turno;

import com.co.eurekatic.aicontrol.agente.comun.ErrorAgente;
import com.co.eurekatic.aicontrol.agente.comun.UsuarioAgente;
import com.co.eurekatic.aicontrol.agente.persistencia.conversacion.ConversacionStore;
import com.co.eurekatic.aicontrol.agente.persistencia.conversacion.ConversacionStore.Conversacion;
import com.co.eurekatic.aicontrol.agente.persistencia.conversacion.EstadoConversacion;
import com.co.eurekatic.aicontrol.agente.persistencia.mensaje.MensajeStore;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.time.LocalDateTime;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ConversacionesServiceTest {

    private static final UsuarioAgente USUARIO = new UsuarioAgente(7L, Set.of("DOCENTE"), "token");

    private final UUID id = UUID.randomUUID();
    private ConversacionStore store;
    private ConversacionesService servicio;

    @BeforeEach
    void setUp() {
        store = mock(ConversacionStore.class);
        servicio = new ConversacionesService(store, mock(MensajeStore.class));
    }

    @Test
    void unaConversacionAjenaNoExiste() {
        when(store.buscar(eq(id), anyLong())).thenReturn(Optional.empty());

        assertThatThrownBy(() -> servicio.activa(id, USUARIO)).isInstanceOf(ErrorAgente.ConversacionNoEncontrada.class);
    }

    @Test
    void unaConversacionArchivadaNoAdmiteMensajes() {
        when(store.buscar(eq(id), anyLong())).thenReturn(Optional.of(conversacion(EstadoConversacion.ARCHIVADA)));

        assertThatThrownBy(() -> servicio.activa(id, USUARIO)).isInstanceOf(ErrorAgente.ConversacionCerrada.class);
    }

    @Test
    void archivarUnaAjenaDaNoEncontrada() {
        when(store.archivar(any(), anyLong())).thenReturn(false);

        assertThatThrownBy(() -> servicio.archivar(id, USUARIO)).isInstanceOf(ErrorAgente.ConversacionNoEncontrada.class);
    }

    @Test
    void unaConversacionActivaSeEntrega() {
        when(store.buscar(eq(id), anyLong())).thenReturn(Optional.of(conversacion(EstadoConversacion.ACTIVA)));

        assertThat(servicio.activa(id, USUARIO).id()).isEqualTo(id);
    }

    private Conversacion conversacion(EstadoConversacion estado) {
        return new Conversacion(id, 7L, "Nueva", estado, LocalDateTime.now(), LocalDateTime.now());
    }
}
