package com.co.eurekatic.ssoadmin.controller;

import com.co.eurekatic.common.entity.Microservice;
import com.co.eurekatic.common.repository.MicroserviceRepository;
import com.co.eurekatic.ssoadmin.exception.GlobalExceptionHandler;
import com.co.eurekatic.ssoadmin.provisioner.ContainerProvisioner;
import com.co.eurekatic.ssoadmin.provisioner.ProvisioningException;
import com.co.eurekatic.ssoadmin.service.MicroserviceService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.util.Optional;

import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Focused controller test for the three container-ops endpoints
 * ({@code /container/status}, {@code /container/logs},
 * {@code /container/restart}). Uses
 * {@link MockMvcBuilders#standaloneSetup} (no Spring context)
 * to keep each test in the millisecond range — the security
 * path is exercised separately by
 * {@code SsoAdminIntegrationTest}.
 *
 * <p>The provisioner and the microservice repository are mocked
 * — these tests verify the controller's <em>shape</em> (lookup
 * row, validate kind=QUERY, derive container name, delegate,
 * map response) without booting a real provisioner.
 *
 * <p>{@link GlobalExceptionHandler} is wired explicitly so the
 * 404/422/502 paths that the controller relies on are exercised
 * end-to-end.
 */
class MicroserviceControllerContainerOpsTest {

    private MicroserviceRepository repo;
    private ContainerProvisioner provisioner;
    private MockMvc mvc;

    @BeforeEach
    void setUp() {
        repo = mock(MicroserviceRepository.class);
        provisioner = mock(ContainerProvisioner.class);
        MicroserviceService service = mock(MicroserviceService.class);
        mvc = MockMvcBuilders
                .standaloneSetup(new MicroserviceController(service, repo, provisioner))
                .setControllerAdvice(new GlobalExceptionHandler())
                .build();
    }

    /* ====================== GET /container/status ====================== */

    @Test
    void getStatusReturnsRunningShapeWhenContainerIsUp() throws Exception {
        when(repo.findById(7L)).thenReturn(Optional.of(queryRow(7L, "oracle-dev")));
        when(provisioner.status("query-service-oracle-dev"))
                .thenReturn(new ContainerProvisioner.ContainerStatus(
                        "running", "running", "abc123",
                        "2026-06-24T15:04:05Z", "query-service-oracle-dev"));

        mvc.perform(get("/microservice/7/container/status"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.state").value("running"))
                .andExpect(jsonPath("$.rawState").value("running"))
                .andExpect(jsonPath("$.containerId").value("abc123"))
                .andExpect(jsonPath("$.startedAt").value("2026-06-24T15:04:05Z"))
                .andExpect(jsonPath("$.fullName").value("query-service-oracle-dev"));
    }

    @Test
    void getStatusReturnsAbsentShapeWhenContainerGone() throws Exception {
        // The provisioner contract for absent is 200 + state="absent",
        // NOT a 404. The admin-ui badge component relies on this to
        // render an ABSENT pill rather than crashing on 404.
        when(repo.findById(8L)).thenReturn(Optional.of(queryRow(8L, "pg")));
        when(provisioner.status("query-service-pg"))
                .thenReturn(new ContainerProvisioner.ContainerStatus(
                        "absent", "absent", null, null, "query-service-pg"));

        mvc.perform(get("/microservice/8/container/status"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.state").value("absent"))
                .andExpect(jsonPath("$.containerId").doesNotExist())
                .andExpect(jsonPath("$.startedAt").doesNotExist());
    }

    @Test
    void getStatusReturns404WhenMicroserviceRowMissing() throws Exception {
        when(repo.findById(99L)).thenReturn(Optional.empty());

        mvc.perform(get("/microservice/99/container/status"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.code").value("NOT_FOUND"));
        // We must NOT touch the provisioner when the row is gone —
        // there's no container name to ask about.
        verify(provisioner, never()).status(anyString());
    }

    @Test
    void getStatusReturns400WhenRowIsRestKind() throws Exception {
        // REST rows have no container — calling the container
        // endpoint on one is a 400 INVALID_REQUEST (the row
        // exists, but the request is wrong for it). The 400
        // path is the existing IllegalArgumentException →
        // GlobalExceptionHandler mapping; using the same code
        // here keeps the controller surface consistent with
        // the kind=QUERY cross-field validation.
        Microservice restRow = queryRow(11L, "orders-svc");
        restRow.setKind("REST");
        when(repo.findById(11L)).thenReturn(Optional.of(restRow));

        mvc.perform(get("/microservice/11/container/status"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value("INVALID_REQUEST"));
        verify(provisioner, never()).status(anyString());
    }

    @Test
    void getStatusMapsProvisionerUnreachableTo503() throws Exception {
        when(repo.findById(7L)).thenReturn(Optional.of(queryRow(7L, "oracle-dev")));
        when(provisioner.status("query-service-oracle-dev"))
                .thenThrow(new ProvisioningException(
                        ProvisioningException.Code.SIDECAR_UNREACHABLE,
                        "connection refused"));

        mvc.perform(get("/microservice/7/container/status"))
                .andExpect(status().isServiceUnavailable())
                .andExpect(jsonPath("$.code").value("SIDECAR_UNREACHABLE"));
    }

    /* ====================== GET /container/logs ====================== */

    @Test
    void getLogsReturnsPlainTextBodyWithDefaultTail() throws Exception {
        when(repo.findById(7L)).thenReturn(Optional.of(queryRow(7L, "oracle-dev")));
        when(provisioner.logs(eq("query-service-oracle-dev"), eq(200)))
                .thenReturn("2026-06-24 INFO started\n");

        mvc.perform(get("/microservice/7/container/logs"))
                .andExpect(status().isOk())
                .andExpect(content().contentTypeCompatibleWith("text/plain"))
                .andExpect(content().string("2026-06-24 INFO started\n"));
    }

    @Test
    void getLogsForwardsTailParam() throws Exception {
        when(repo.findById(7L)).thenReturn(Optional.of(queryRow(7L, "oracle-dev")));
        when(provisioner.logs(eq("query-service-oracle-dev"), eq(500)))
                .thenReturn("tail-500\n");

        mvc.perform(get("/microservice/7/container/logs").param("tail", "500"))
                .andExpect(status().isOk())
                .andExpect(content().string("tail-500\n"));
    }

    @Test
    void getLogsReturnsEmptyStringWhenContainerSilent() throws Exception {
        when(repo.findById(7L)).thenReturn(Optional.of(queryRow(7L, "oracle-dev")));
        when(provisioner.logs(anyString(), anyInt())).thenReturn("");

        mvc.perform(get("/microservice/7/container/logs"))
                .andExpect(status().isOk())
                .andExpect(content().string(""));
    }

    /* ====================== POST /container/restart ====================== */

    @Test
    void postRestartReturns202WhenContainerExists() throws Exception {
        when(repo.findById(7L)).thenReturn(Optional.of(queryRow(7L, "oracle-dev")));
        when(provisioner.restart("query-service-oracle-dev")).thenReturn(true);

        mvc.perform(post("/microservice/7/container/restart"))
                .andExpect(status().isAccepted());
    }

    @Test
    void postRestartReturns404WhenContainerGone() throws Exception {
        // provisioner.restart returns false for an absent
        // container — the controller translates that to 404
        // so the admin-ui can offer a "recreate" action.
        when(repo.findById(8L)).thenReturn(Optional.of(queryRow(8L, "pg")));
        when(provisioner.restart("query-service-pg")).thenReturn(false);

        mvc.perform(post("/microservice/8/container/restart"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.code").value("NOT_FOUND"));
    }

    @Test
    void postRestartReturns400WhenRowIsRestKind() throws Exception {
        Microservice restRow = queryRow(11L, "orders-svc");
        restRow.setKind("REST");
        when(repo.findById(11L)).thenReturn(Optional.of(restRow));

        mvc.perform(post("/microservice/11/container/restart"))
                .andExpect(status().isBadRequest());
        verify(provisioner, never()).restart(anyString());
    }

    /* ====================== helpers ====================== */

    /** A QUERY-kind row with the given suffix as {@code instanceName}. */
    private static Microservice queryRow(long id, String instanceName) {
        Microservice m = new Microservice();
        m.setId(id);
        m.setKind("QUERY");
        m.setServiceId("query-" + instanceName);
        m.setDescription("");
        m.setRequestUri("/api/queries/**");
        m.setTargetUriPath("");
        m.setTargetUrlHost("");
        m.setTargetUrlPort("");
        m.setDialect("oracle");
        m.setJdbcUrl("jdbc:oracle:thin:@db:1521/X");
        m.setDbUsername("query");
        m.setInstanceName(instanceName);
        return m;
    }
}