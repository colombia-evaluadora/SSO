package com.co.eurekatic.provisioner;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Standalone MockMvc test for {@link ProvisionerController}.
 * Uses {@link MockMvcBuilders#standaloneSetup} instead of
 * {@code @WebMvcTest} to keep the test dependency surface
 * minimal — the controller is small and self-contained,
 * and standalone setup exercises the JSON binding +
 * validation + response shape without booting a Spring
 * context.
 *
 * <p>{@link DockerSocket} is replaced with a Mockito mock so
 * the test never tries to talk to a real Docker daemon —
 * those end-to-end checks live behind the compose smoke
 * test, not here.
 */
class ProvisionerControllerTest {

    private DockerSocket docker;
    private MockMvc mvc;

    @BeforeEach
    void setUp() {
        docker = mock(DockerSocket.class);
        // The controller doesn't currently pull in
        // ProvisionerProperties — keeps the dependency
        // graph thin.
        mvc = MockMvcBuilders
                .standaloneSetup(new ProvisionerController(docker))
                .build();
    }

    @Test
    void postProvisionReturns201AndForwardsSpecToDocker() throws Exception {
        when(docker.createAndStart(any(), eq("query-service-oracle-dev")))
                .thenReturn("abc123");

        mvc.perform(post("/provision")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {
                                  "instanceName": "oracle-dev",
                                  "dialect": "oracle",
                                  "jdbcUrl": "jdbc:oracle:thin:@db:1521/ORCLPDB1",
                                  "dbUsername": "query",
                                  "dbPassword": "change-me",
                                  "poolSize": 10
                                }
                                """))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.instanceName").value("query-service-oracle-dev"))
                .andExpect(jsonPath("$.containerId").value("abc123"))
                .andExpect(jsonPath("$.status").value("running"));

        verify(docker).createAndStart(any(), eq("query-service-oracle-dev"));
    }

    @Test
    void postProvisionRejectsBlankInstanceName() throws Exception {
        mvc.perform(post("/provision")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {
                                  "instanceName": "",
                                  "dialect": "postgres",
                                  "jdbcUrl": "jdbc:postgresql://db:5432/x",
                                  "dbUsername": "u",
                                  "poolSize": 5
                                }
                                """))
                .andExpect(status().isBadRequest());
    }

    @Test
    void deleteProvisionReturns204() throws Exception {
        mvc.perform(delete("/provision/query-service-oracle-dev"))
                .andExpect(status().isNoContent());
        verify(docker).stopAndRemove("query-service-oracle-dev");
    }

    @Test
    void getStatusReturns200WhenContainerRunning() throws Exception {
        when(docker.status("query-service-postgres")).thenReturn("running");

        mvc.perform(get("/provision/query-service-postgres/status"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("running"));
    }

    @Test
    void getStatusReturns200WithAbsentWhenContainerMissing() throws Exception {
        // Contract: missing container is a 200 with status="absent",
        // NOT a 404. The admin-ui badge for "absent" is what the
        // operator sees while a row exists but the container
        // is gone (race on delete, manual `docker rm`, etc).
        when(docker.status("query-service-gone")).thenReturn("absent");
        when(docker.inspectStartedAt("query-service-gone")).thenReturn(null);

        mvc.perform(get("/provision/query-service-gone/status"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("absent"))
                .andExpect(jsonPath("$.instanceName").value("query-service-gone"))
                .andExpect(jsonPath("$.containerId").doesNotExist())
                .andExpect(jsonPath("$.startedAt").doesNotExist());
    }

    @Test
    void getStatusIncludesStartedAtAndContainerIdWhenPresent() throws Exception {
        when(docker.status("query-service-postgres")).thenReturn("running");
        when(docker.inspectStartedAt("query-service-postgres"))
                .thenReturn(new DockerSocket.StartedAtInfo("abc123",
                        "2026-06-24T15:04:05.123456789Z"));

        mvc.perform(get("/provision/query-service-postgres/status"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("running"))
                .andExpect(jsonPath("$.containerId").value("abc123"))
                .andExpect(jsonPath("$.startedAt")
                        .value("2026-06-24T15:04:05.123456789Z"));
    }

    @Test
    void getLogsReturnsTextBodyWithDefaultTail() throws Exception {
        when(docker.logs("query-service-postgres", 200))
                .thenReturn("2026-06-24 INFO started\n");

        mvc.perform(get("/provision/query-service-postgres/logs"))
                .andExpect(status().isOk())
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers
                        .content().string("2026-06-24 INFO started\n"));
    }

    @Test
    void getLogsForwardsTailParameter() throws Exception {
        when(docker.logs("query-service-postgres", 500))
                .thenReturn("tail-500\n");

        mvc.perform(get("/provision/query-service-postgres/logs").param("tail", "500"))
                .andExpect(status().isOk())
                .andExpect(org.springframework.test.web.servlet.result.MockMvcResultMatchers
                        .content().string("tail-500\n"));
    }

    @Test
    void getLogsClampsTailToMaximum() throws Exception {
        // Operator asks for 1_000_000 lines; the controller caps at 100k
        // to avoid a multi-GB response.
        when(docker.logs(eq("query-service-postgres"), eq(100_000)))
                .thenReturn("capped\n");

        mvc.perform(get("/provision/query-service-postgres/logs").param("tail", "1000000"))
                .andExpect(status().isOk());
        verify(docker).logs("query-service-postgres", 100_000);
    }

    @Test
    void getLogsClampsTailToMinimum() throws Exception {
        // tail=0 would be a no-op; clamp to 1.
        when(docker.logs(eq("query-service-postgres"), eq(1)))
                .thenReturn("one\n");

        mvc.perform(get("/provision/query-service-postgres/logs").param("tail", "0"))
                .andExpect(status().isOk());
        verify(docker).logs("query-service-postgres", 1);
    }

    @Test
    void postRestartReturns204WhenContainerExists() throws Exception {
        when(docker.restart("query-service-postgres")).thenReturn(true);

        mvc.perform(post("/provision/query-service-postgres/restart"))
                .andExpect(status().isNoContent());
        verify(docker).restart("query-service-postgres");
    }

    @Test
    void postRestartReturns404WhenContainerMissing() throws Exception {
        when(docker.restart("query-service-gone")).thenReturn(false);

        mvc.perform(post("/provision/query-service-gone/restart"))
                .andExpect(status().isNotFound());
    }
}