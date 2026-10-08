package com.co.eurekatic.auth.client;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.content;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.header;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.method;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withNoContent;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;

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
}
