package com.co.eurekatic.comms.chat;

import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class MencionesTest {

    private final Map<Long, String> miembros = Map.of(7L, "Ana Rios", 9L, "Luis Paz");

    @Test
    void soloMiembrosYSinDuplicados() {
        var ms = Menciones.extraer("hola <@7> y <@7> y <@99>", miembros, false);
        assertThat(ms).hasSize(1);
        assertThat(ms.get(0).usuarioId()).isEqualTo(7L);
        assertThat(ms.get(0).nombre()).isEqualTo("Ana Rios");
    }

    @Test
    void masivasSoloConPermiso() {
        assertThat(Menciones.extraer("@todos atentos", miembros, false)).isEmpty();
        var ms = Menciones.extraer("@todos y @Canal, correo@canal.com no", miembros, true);
        assertThat(ms).extracting(ChatDtos.Mencion::tipo).containsExactly("TODOS", "CANAL");
    }
}
