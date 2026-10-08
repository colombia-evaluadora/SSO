package com.co.eurekatic.auth.client;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.content;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.header;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.method;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withNoContent;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

class SsoAdminInternalClientTest {

    private static final String URL =
            "http://sso-admin/internal/funcionario/reactivar-por-cambio-de-correo?app=PIGSE";

    MockRestServiceServer server;
    SsoAdminInternalClient client;

    @BeforeEach
    void setUp() {
        RestClient.Builder builder = RestClient.builder().baseUrl("http://sso-admin");
        server = MockRestServiceServer.bindTo(builder).build();
        client = new SsoAdminInternalClient(builder.build(), "secreto");
    }

    @Test
    void enviaTokenInternoYCorreos() {
        server.expect(requestTo(URL))
                .andExpect(method(HttpMethod.POST))
                .andExpect(header("X-Internal-Token", "secreto"))
                .andExpect(content().json("{\"correoAnterior\":\"a@x.co\",\"correoNuevo\":\"b@x.co\"}"))
                .andRespond(withNoContent());

        client.reactivateAfterEmailChange("a@x.co", "b@x.co", "PIGSE");
        server.verify();
    }

    @Test
    void un400DeSsoAdminConservaElMensaje() {
        server.expect(requestTo(URL)).andRespond(withStatus(HttpStatus.BAD_REQUEST)
                .contentType(MediaType.APPLICATION_JSON)
                .body("{\"message\":\"El correo no cambió\"}"));

        assertThatThrownBy(() -> client.reactivateAfterEmailChange("a@x.co", "b@x.co", "PIGSE"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("El correo no cambió");
    }

    @Test
    void un422DeSsoAdminTambienEsRechazoConMensaje() {
        server.expect(requestTo(URL)).andRespond(withStatus(HttpStatus.UNPROCESSABLE_ENTITY)
                .contentType(MediaType.APPLICATION_JSON)
                .body("{\"message\":\"Correo invalido\"}"));

        assertThatThrownBy(() -> client.reactivateAfterEmailChange("a@x.co", "b@x.co", "PIGSE"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("Correo invalido");
    }

    @Test
    void un401EsErrorDeInfraestructura() {
        server.expect(requestTo(URL)).andRespond(withStatus(HttpStatus.UNAUTHORIZED));

        assertThatThrownBy(() -> client.reactivateAfterEmailChange("a@x.co", "b@x.co", "PIGSE"))
                .isInstanceOf(IllegalStateException.class);
    }

    @Test
    void sinTokenNoLlama() {
        SsoAdminInternalClient sinToken = new SsoAdminInternalClient(RestClient.create(), "");
        assertThatThrownBy(() -> sinToken.reactivateAfterEmailChange("a@x.co", "b@x.co", "CE"))
                .isInstanceOf(IllegalStateException.class);
    }

    @Test
    void estadoCuentaDevuelveFilas() {
        server.expect(requestTo("http://sso-admin/internal/funcionario/estado-cuenta"))
                .andExpect(header("X-Internal-Token", "secreto"))
                .andExpect(content().json("{\"correos\":[\"a@x.co\"]}"))
                .andRespond(withSuccess("[{\"correo\":\"a@x.co\",\"estado\":\"PENDING_ACTIVATION\"}]",
                        MediaType.APPLICATION_JSON));

        assertThat(client.accountStatus(java.util.List.of("a@x.co")))
                .containsExactly(new com.co.eurekatic.auth.web.dto.EstadoCuentaFuncionarioResponse(
                        "a@x.co", "PENDING_ACTIVATION"));
        server.verify();
    }

    @Test
    void reenvioEnviaCorreoYApp() {
        server.expect(requestTo("http://sso-admin/internal/funcionario/reenviar-activacion?app=PIGSE"))
                .andExpect(method(HttpMethod.POST))
                .andExpect(header("X-Internal-Token", "secreto"))
                .andExpect(content().json("{\"correo\":\"a@x.co\"}"))
                .andRespond(withNoContent());

        client.resendActivation("a@x.co", "PIGSE");
        server.verify();
    }

    @Test
    void reenvio409ConservaStatusYMensaje() {
        server.expect(requestTo("http://sso-admin/internal/funcionario/reenviar-activacion?app=PIGSE"))
                .andRespond(withStatus(HttpStatus.CONFLICT).contentType(MediaType.APPLICATION_JSON)
                        .body("{\"message\":\"La cuenta ya está activa; usa restablecer contraseña.\"}"));

        assertThatThrownBy(() -> client.resendActivation("a@x.co", "PIGSE"))
                .isInstanceOfSatisfying(SsoAdminStatusException.class, e -> {
                    assertThat(e.status()).isEqualTo(409);
                    assertThat(e.getMessage()).isEqualTo("La cuenta ya está activa; usa restablecer contraseña.");
                });
    }

    @Test
    void reenvio404ConservaStatus() {
        server.expect(requestTo("http://sso-admin/internal/funcionario/reenviar-activacion?app=CE"))
                .andRespond(withStatus(HttpStatus.NOT_FOUND));

        assertThatThrownBy(() -> client.resendActivation("a@x.co", "CE"))
                .isInstanceOfSatisfying(SsoAdminStatusException.class, e -> assertThat(e.status()).isEqualTo(404));
    }
}
