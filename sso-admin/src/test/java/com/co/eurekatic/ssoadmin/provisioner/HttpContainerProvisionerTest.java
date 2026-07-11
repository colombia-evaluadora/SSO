package com.co.eurekatic.ssoadmin.provisioner;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.content;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.header;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.method;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.queryParam;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withNoContent;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withServerError;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

/**
 * Tests {@link HttpContainerProvisioner} against a
 * {@link MockRestServiceServer} — we don't spin up a real
 * provisioner; instead we assert the wire shape the client
 * expects and the error mapping it applies.
 *
 * <p>The {@link RestClient.Builder#uriFactory} / baseUrl pair
 * is shared between the production client and the mock server
 * — that's how MockRestServiceServer intercepts requests.
 */
class HttpContainerProvisionerTest {

    private static final String BASE = "http://provisioner.test:9000";

    private MockRestServiceServer server;
    private HttpContainerProvisioner provisioner;

    @BeforeEach
    void setUp() {
        RestClient.Builder builder = RestClient.builder().baseUrl(BASE);
        // Binding the mock to THIS builder means every
        // RestClient built from it gets intercepted. The
        // package-private HttpContainerProvisioner(builder)
        // ctor takes this exact builder, so the requests
        // made by the production code go through the mock.
        server = MockRestServiceServer.bindTo(builder).build();
        provisioner = new HttpContainerProvisioner(builder);
    }

    /* ====================== status ====================== */

    @Test
    void statusDeserializesProvisionerResponse() {
        server.expect(requestTo(BASE + "/provision/query-service-oracle-dev/status"))
                .andExpect(method(org.springframework.http.HttpMethod.GET))
                .andExpect(header("Accept", MediaType.APPLICATION_JSON_VALUE))
                .andRespond(withSuccess("""
                        {
                          "instanceName": "query-service-oracle-dev",
                          "containerId": "abc123",
                          "status": "running",
                          "startedAt": "2026-06-24T15:04:05Z",
                          "rawState": "running"
                        }
                        """, MediaType.APPLICATION_JSON));

        ContainerProvisioner.ContainerStatus s =
                provisioner.status("query-service-oracle-dev");

        assertThat(s.state()).isEqualTo("running");
        assertThat(s.rawState()).isEqualTo("running");
        assertThat(s.containerId()).isEqualTo("abc123");
        assertThat(s.startedAt()).isEqualTo("2026-06-24T15:04:05Z");
        assertThat(s.fullName()).isEqualTo("query-service-oracle-dev");
        server.verify();
    }

    @Test
    void statusFallsBackToFullNameWhenInstanceNameAbsent() {
        // Some older provisioner builds omit instanceName; the
        // client echoes the input name in that case so the
        // admin-ui badge still has a usable fullName.
        server.expect(requestTo(BASE + "/provision/query-service-x/status"))
                .andRespond(withSuccess("""
                        { "status": "absent", "containerId": null, "startedAt": null }
                        """, MediaType.APPLICATION_JSON));

        ContainerProvisioner.ContainerStatus s =
                provisioner.status("query-service-x");
        assertThat(s.state()).isEqualTo("absent");
        assertThat(s.fullName()).isEqualTo("query-service-x");
    }

    @Test
    void statusMapsProvisioner4xxToContainerCreateFailed() {
        server.expect(requestTo(BASE + "/provision/query-service-x/status"))
                .andRespond(withStatus(org.springframework.http.HttpStatus.BAD_REQUEST));

        assertThatThrownBy(() -> provisioner.status("query-service-x"))
                .isInstanceOf(ProvisioningException.class)
                .extracting("code").isEqualTo(ProvisioningException.Code.CONTAINER_CREATE_FAILED);
    }

    @Test
    void statusMapsProvisioner5xxToSidecarUnreachable() {
        server.expect(requestTo(BASE + "/provision/query-service-x/status"))
                .andRespond(withServerError());

        assertThatThrownBy(() -> provisioner.status("query-service-x"))
                .isInstanceOf(ProvisioningException.class)
                .extracting("code").isEqualTo(ProvisioningException.Code.SIDECAR_UNREACHABLE);
    }

    /* ====================== logs ====================== */

    @Test
    void logsForwardsTailParameter() {
        server.expect(requestTo(BASE + "/provision/query-service-oracle-dev/logs?tail=500"))
                .andExpect(method(org.springframework.http.HttpMethod.GET))
                .andExpect(queryParam("tail", "500"))
                .andRespond(withSuccess("first\nsecond\n", MediaType.TEXT_PLAIN));

        String body = provisioner.logs("query-service-oracle-dev", 500);
        assertThat(body).isEqualTo("first\nsecond\n");
        server.verify();
    }

    @Test
    void logsReturnsEmptyStringWhenProvisionerReturnsEmpty() {
        server.expect(requestTo(BASE + "/provision/query-service-x/logs?tail=200"))
                .andRespond(withSuccess("", MediaType.TEXT_PLAIN));

        assertThat(provisioner.logs("query-service-x", 200)).isEmpty();
    }

    @Test
    void logsMapsProvisioner5xxToSidecarUnreachable() {
        server.expect(requestTo(BASE + "/provision/query-service-x/logs?tail=200"))
                .andRespond(withServerError());

        assertThatThrownBy(() -> provisioner.logs("query-service-x", 200))
                .isInstanceOf(ProvisioningException.class)
                .extracting("code").isEqualTo(ProvisioningException.Code.SIDECAR_UNREACHABLE);
    }

    /* ====================== restart ====================== */

    @Test
    void restartPostsAndReturnsTrueOn204() {
        server.expect(requestTo(BASE + "/provision/query-service-oracle-dev/restart"))
                .andExpect(method(org.springframework.http.HttpMethod.POST))
                .andRespond(withNoContent());

        assertThat(provisioner.restart("query-service-oracle-dev")).isTrue();
        server.verify();
    }

    @Test
    void restartReturnsFalseOn404ContainerGone() {
        // 404 is the success path for "container is already
        // gone" — the client returns false rather than
        // throwing so the controller can map it to a 404
        // response (or an absent badge on the page).
        server.expect(requestTo(BASE + "/provision/query-service-x/restart"))
                .andRespond(withStatus(org.springframework.http.HttpStatus.NOT_FOUND));

        assertThat(provisioner.restart("query-service-x")).isFalse();
    }

    @Test
    void restartMapsProvisioner4xxToContainerCreateFailed() {
        server.expect(requestTo(BASE + "/provision/query-service-x/restart"))
                .andRespond(withStatus(org.springframework.http.HttpStatus.BAD_REQUEST));

        assertThatThrownBy(() -> provisioner.restart("query-service-x"))
                .isInstanceOf(ProvisioningException.class)
                .extracting("code").isEqualTo(ProvisioningException.Code.CONTAINER_CREATE_FAILED);
    }

    /* ====================== provision (existing happy path regression) ====================== */

    @Test
    void provisionPostsSpecAndIgnoresSuccessBody() {
        server.expect(requestTo(BASE + "/provision"))
                .andExpect(method(org.springframework.http.HttpMethod.POST))
                .andExpect(content().contentTypeCompatibleWith(MediaType.APPLICATION_JSON))
                .andRespond(withSuccess("""
                        {"instanceName":"query-service-oracle-dev","containerId":"abc","status":"running"}
                        """, MediaType.APPLICATION_JSON));

        provisioner.provision(new ProvisionSpec(
                "oracle-dev", "oracle", "jdbc:oracle:thin:@db/x",
                "u", "p", 10));
        server.verify();
    }
}