package com.co.eurekatic.aicontrol.observaciones;

import com.co.eurekatic.aicontrol.llm.ModeloInvoker;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.net.SocketTimeoutException;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class SalidaModeloTest {

    @Test
    void parseaElObjetoDirecto() {
        var r = SalidaModelo.parsear("""
                {"introduccion":"Hola.","dimensiones":[{"nombre":"Comunicativa","descripcion":"Narra."}],
                 "fortalezas":["a"],"aspectosPorFortalecer":[],"recomendaciones":[],"sintesis":"Fin."}""");
        assertThat(r.introduccion()).isEqualTo("Hola.");
        assertThat(r.dimensiones()).hasSize(1);
    }

    /** Lo que devolvio Nemotron 3.5 Lightning en una llamada real. */
    @Test
    void desenvuelveUnJsonSchemaCopiadoPorElModelo() {
        var r = SalidaModelo.parsear("""
                {"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object",
                 "properties":{"introduccion":"Durante el periodo...","fortalezas":["Participa"],
                   "dimensiones":[],"aspectosPorFortalecer":[],"recomendaciones":[],"sintesis":"Fin."},
                 "required":["introduccion"],"additionalProperties":false}""");
        assertThat(r.introduccion()).isEqualTo("Durante el periodo...");
        assertThat(r.fortalezas()).containsExactly("Participa");
    }

    @Test
    void quitaCercasDeMarkdownYTextoAlrededor() {
        var r = SalidaModelo.parsear("""
                ```json
                {"introduccion":"Hola.","sintesis":"Fin.","campoExtra":1}
                ```""");
        assertThat(r.sintesis()).isEqualTo("Fin.");
    }

    @Test
    void rechazaLoQueNoTieneLaForma() {
        assertThatThrownBy(() -> SalidaModelo.parsear("{\"otra\":1}")).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> SalidaModelo.parsear("lo siento, no puedo")).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> SalidaModelo.parsear("")).isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void reconoceTimeoutsEnvueltosPorElSdk() {
        assertThat(ModeloInvoker.esTimeout(new RuntimeException("Request failed",
                new IOException("x", new SocketTimeoutException("timeout"))))).isTrue();
        assertThat(ModeloInvoker.esTimeout(new RuntimeException("401"))).isFalse();
    }
}
