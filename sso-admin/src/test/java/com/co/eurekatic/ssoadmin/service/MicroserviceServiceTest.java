package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Microservice;
import com.co.eurekatic.common.repository.AppRepository;
import com.co.eurekatic.common.repository.MicroserviceRepository;
import com.co.eurekatic.ssoadmin.dto.MicroserviceRequest;
import com.co.eurekatic.ssoadmin.dto.MicroserviceResponse;
import com.co.eurekatic.ssoadmin.dto.MicroserviceTestConnectionRequest;
import com.co.eurekatic.ssoadmin.dto.MicroserviceTestConnectionResponse;
import com.co.eurekatic.ssoadmin.exception.DuplicateException;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import com.co.eurekatic.ssoadmin.provisioner.ContainerProvisioner;
import com.co.eurekatic.ssoadmin.provisioner.EurekaReadinessProbe;
import com.co.eurekatic.ssoadmin.provisioner.ProvisionSpec;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Unit tests for {@link MicroserviceService}. The provisioner
 * sidecar is mocked — these tests don't go anywhere near
 * Docker. The two QUERY-specific tests assert the provisioner
 * is invoked with the right {@link ProvisionSpec} and that
 * REST rows do NOT touch the provisioner (the negative case
 * that drove the split).
 */
@ExtendWith(MockitoExtension.class)
class MicroserviceServiceTest {

    @Mock MicroserviceRepository repo;
    @Mock AppRepository appRepo;
    @Mock ContainerProvisioner provisioner;
    @Mock EurekaReadinessProbe readinessProbe;
    @Mock JdbcConnectionProbe connectionProbe;
    @InjectMocks MicroserviceService service;

    /** Sonda JDBC en verde — el caso normal para los tests de QUERY. */
    private void probeSucceeds() {
        when(connectionProbe.probe(any(MicroserviceTestConnectionRequest.class)))
                .thenReturn(MicroserviceTestConnectionResponse.success("postgres", 3));
    }

    private static Microservice sample(long id) {
        Microservice m = new Microservice();
        m.setId(id);
        m.setKind("REST");
        m.setServiceId("svc-" + id);
        m.setDescription("desc " + id);
        m.setRequestUri("/req");
        m.setTargetUriPath("/path");
        m.setTargetUrlHost("host");
        m.setTargetUrlPort("8080");
        return m;
    }

    /** Builds a 6-arg REST request (all QUERY-only fields null).
     *  Saves the noisy repetition below. */
    private static MicroserviceRequest restRequest(Long id, String serviceId) {
        return new MicroserviceRequest(
                id, serviceId, "d", "/req", "/path", "host", "8080",
                /*kind*/ "REST",
                /*dialect*/ null, /*jdbcUrl*/ null, /*dbUsername*/ null,
                /*dbPassword*/ null, /*poolSize*/ null, /*instanceName*/ null,
                /*appId*/ null,
                /*fileStorageSchema*/ null, /*fileStorageTable*/ null);
    }

    /** Builds a 14-arg QUERY request with valid JDBC metadata. */
    private static MicroserviceRequest queryRequest(String instanceName) {
        return new MicroserviceRequest(
                /*id*/ null,
                /*serviceId*/ "query-" + instanceName,
                /*description*/ "d",
                /*requestUri*/ "/req",
                /*targetUriPath*/ "/path",
                /*targetUrlHost*/ "host",
                /*targetUrlPort*/ "8080",
                /*kind*/ "QUERY",
                /*dialect*/ "postgres",
                /*jdbcUrl*/ "jdbc:postgresql://db:5432/x",
                /*dbUsername*/ "user",
                /*dbPassword*/ "secret",
                /*poolSize*/ 5,
                /*instanceName*/ instanceName,
                /*appId*/ null,
                /*fileStorageSchema*/ null, /*fileStorageTable*/ null);
    }

    /* ====================== legacy (REST) CRUD ====================== */

    @Test
    void createRejectsDuplicateServiceId() {
        when(repo.existsByServiceId("dup")).thenReturn(true);
        MicroserviceRequest req = restRequest(null, "dup");

        assertThatThrownBy(() -> service.create(req))
                .isInstanceOf(DuplicateException.class)
                .hasMessageContaining("dup");
    }

    @Test
    void createPersistsNewMicroservice() {
        when(repo.existsByServiceId("new")).thenReturn(false);
        when(repo.save(any(Microservice.class))).thenAnswer(inv -> {
            Microservice m = inv.getArgument(0);
            m.setId(42L);
            return m;
        });

        MicroserviceResponse resp = service.create(restRequest(null, "new"));

        assertThat(resp.id()).isEqualTo(42L);
        assertThat(resp.serviceId()).isEqualTo("new");
        assertThat(resp.targetUrlPort()).isEqualTo("8080");
        // REST rows must NOT touch the provisioner or the
        // Eureka probe — that's the whole point of the
        // kind discriminator.
        verify(provisioner, never()).provision(any());
        verify(readinessProbe, never()).waitForInstance(anyString());
    }

    @Test
    void updateRejectsMissingId() {
        MicroserviceRequest req = restRequest(null, "x");
        assertThatThrownBy(() -> service.update(req))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void updateThrowsWhenMicroserviceMissing() {
        when(repo.findById(99L)).thenReturn(Optional.empty());
        MicroserviceRequest req = restRequest(99L, "x");

        assertThatThrownBy(() -> service.update(req))
                .isInstanceOf(NotFoundException.class);
    }

    @Test
    void updateAppliesAllFields() {
        Microservice m = sample(7L);
        when(repo.findById(7L)).thenReturn(Optional.of(m));
        when(repo.save(m)).thenReturn(m);

        MicroserviceResponse resp = service.update(new MicroserviceRequest(
                7L, "renamed", "new desc", "/new-req", "/new-path", "newhost", "9090",
                "REST",
                null, null, null, null, null, null, null, null, null));

        assertThat(resp.serviceId()).isEqualTo("renamed");
        assertThat(resp.description()).isEqualTo("new desc");
        assertThat(resp.requestUri()).isEqualTo("/new-req");
        assertThat(resp.targetUriPath()).isEqualTo("/new-path");
        assertThat(resp.targetUrlHost()).isEqualTo("newhost");
        assertThat(resp.targetUrlPort()).isEqualTo("9090");
    }

    @Test
    void getAllMapsAllMicroservices() {
        // Build the list BEFORE the stubbing — Mockito's
        // STRICT_STUBS mode rejects non-trivial expressions
        // inside the when() argument list.
        Microservice m1 = sample(1L);
        Microservice m2 = sample(2L);
        when(repo.findAll()).thenReturn(List.of(m1, m2));
        List<MicroserviceResponse> all = service.getAll();
        assertThat(all).extracting(MicroserviceResponse::serviceId)
                .containsExactlyInAnyOrder("svc-1", "svc-2");
    }

    @Test
    void getByIdThrowsWhenMissing() {
        when(repo.findById(99L)).thenReturn(Optional.empty());
        assertThatThrownBy(() -> service.getById(99L))
                .isInstanceOf(NotFoundException.class);
    }

    @Test
    void getByServiceIdThrowsWhenMissing() {
        when(repo.findByServiceId("missing")).thenReturn(Optional.empty());
        assertThatThrownBy(() -> service.getByServiceId("missing"))
                .isInstanceOf(NotFoundException.class);
    }

    @Test
    void deleteThrowsWhenMissing() {
        when(repo.findById(99L)).thenReturn(Optional.empty());
        assertThatThrownBy(() -> service.delete(99L))
                .isInstanceOf(NotFoundException.class);
    }

    /* ====================== QUERY-kind provisioning ====================== */

    @Test
    void queryCreateInvokesProvisionerAndWaitsForEureka() {
        when(repo.existsByServiceId("query-oracle-dev")).thenReturn(false);
        when(repo.existsByInstanceName("oracle-dev")).thenReturn(false);
        probeSucceeds();
        when(repo.save(any(Microservice.class))).thenAnswer(inv -> {
            Microservice m = inv.getArgument(0);
            m.setId(100L);
            return m;
        });

        service.create(queryRequest("oracle-dev"));

        verify(provisioner).provision(new ProvisionSpec(
                "oracle-dev",
                "postgres",
                "jdbc:postgresql://db:5432/x",
                "user",
                "secret",
                5));
        verify(readinessProbe).waitForInstance("query-service-oracle-dev");
    }

    @Test
    void queryCreateWithoutInstanceNameDerivesFromDialect() {
        when(repo.existsByServiceId("query-postgres")).thenReturn(false);
        probeSucceeds();
        when(repo.save(any(Microservice.class))).thenAnswer(inv -> {
            Microservice m = inv.getArgument(0);
            m.setId(101L);
            return m;
        });
        // Same as queryRequest but with instanceName=null.
        MicroserviceRequest req = new MicroserviceRequest(
                null, "query-postgres", null, "/req", "/path", "host", "8080",
                "QUERY", "postgres", "jdbc:postgresql://db:5432/x",
                "user", "secret", 5, /*instanceName*/ null, /*appId*/ null,
                null, null);

        service.create(req);

        // spec.instanceName falls back to dialect when the
        // operator leaves the column null.
        verify(provisioner).provision(new ProvisionSpec(
                "postgres", "postgres",
                "jdbc:postgresql://db:5432/x",
                "user", "secret", 5));
        verify(readinessProbe).waitForInstance("query-service-postgres");
    }

    @Test
    void queryCreateRejectsMissingJdbcUrl() {
        when(repo.existsByServiceId("query-bad")).thenReturn(false);
        MicroserviceRequest req = new MicroserviceRequest(
                null, "query-bad", null, "/req", "/path", "host", "8080",
                "QUERY", "postgres", /*jdbcUrl*/ null,
                "user", "secret", 5, "bad", /*appId*/ null,
                null, null);

        assertThatThrownBy(() -> service.create(req))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("jdbcUrl");
        verify(provisioner, never()).provision(any());
    }

    @Test
    void queryCreateRejectsDuplicateInstanceName() {
        when(repo.existsByServiceId("query-dup")).thenReturn(false);
        when(repo.existsByInstanceName("dup")).thenReturn(true);
        MicroserviceRequest req = queryRequest("dup");

        assertThatThrownBy(() -> service.create(req))
                .isInstanceOf(DuplicateException.class)
                .hasMessageContaining("dup");
        verify(provisioner, never()).provision(any());
    }

    /**
     * El gate de conexión: si la sonda JDBC falla, {@code create}
     * aborta antes del {@code save} — ni fila en BD ni contenedor
     * provisionado. Es el caso que motivó el cambio: antes se
     * creaba el query-service aunque la conexión no funcionara.
     */
    @Test
    void queryCreateAbortsWhenConnectionProbeFails() {
        when(repo.existsByServiceId("query-unreachable")).thenReturn(false);
        when(repo.existsByInstanceName("unreachable")).thenReturn(false);
        when(connectionProbe.probe(any(MicroserviceTestConnectionRequest.class)))
                .thenThrow(new IllegalArgumentException(
                        "No se pudo conectar: connection refused"));

        assertThatThrownBy(() -> service.create(queryRequest("unreachable")))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("No se pudo conectar");

        verify(repo, never()).save(any(Microservice.class));
        verify(provisioner, never()).provision(any());
        verify(readinessProbe, never()).waitForInstance(anyString());
    }

    @Test
    void deleteForQueryDeprovisionsBeforeRowRemoval() {
        Microservice m = sample(11L);
        m.setKind("QUERY");
        m.setDialect("oracle");
        m.setInstanceName("oracle-dev");
        when(repo.findById(11L)).thenReturn(Optional.of(m));

        service.delete(11L);

        verify(provisioner).deprovision("query-service-oracle-dev");
        verify(repo).delete(m);
    }

    /* ====================== recreateContainer ====================== */

    @Test
    void recreateContainerDeprovisionsThenReprovisionsWithTheRowsPersistedSpec() {
        Microservice m = sample(12L);
        m.setKind("QUERY");
        m.setDialect("postgres");
        m.setJdbcUrl("jdbc:postgresql://db:5432/x");
        m.setDbUsername("query");
        m.setDbPassword("secret");
        m.setPoolSize(15);
        m.setInstanceName("eval-col");
        when(repo.findById(12L)).thenReturn(Optional.of(m));

        service.recreateContainer(12L);

        // deprovision antes que provision — recrear es borrar +
        // volver a crear, no un simple restart del mismo contenedor
        // (que reutilizaría el filesystem de la imagen vieja).
        var inOrder = org.mockito.Mockito.inOrder(provisioner);
        inOrder.verify(provisioner).deprovision("query-service-eval-col");
        inOrder.verify(provisioner).provision(new ProvisionSpec(
                "eval-col", "postgres", "jdbc:postgresql://db:5432/x",
                "query", "secret", 15));
        verify(readinessProbe).waitForInstance("query-service-eval-col");
    }

    @Test
    void recreateContainerDefaultsPoolSizeToTenWhenRowHasNone() {
        Microservice m = sample(13L);
        m.setKind("QUERY");
        m.setDialect("oracle");
        m.setInstanceName("oracle-dev");
        m.setPoolSize(null);
        when(repo.findById(13L)).thenReturn(Optional.of(m));

        service.recreateContainer(13L);

        verify(provisioner).provision(new ProvisionSpec(
                "oracle-dev", "oracle", m.getJdbcUrl(), m.getDbUsername(), m.getDbPassword(), 10));
    }

    @Test
    void recreateContainerFallsBackToDialectWhenInstanceNameIsNull() {
        Microservice m = sample(14L);
        m.setKind("QUERY");
        m.setDialect("sqlserver");
        m.setInstanceName(null);
        when(repo.findById(14L)).thenReturn(Optional.of(m));

        service.recreateContainer(14L);

        verify(provisioner).deprovision("query-service-sqlserver");
        verify(readinessProbe).waitForInstance("query-service-sqlserver");
    }

    @Test
    void recreateContainerThrowsNotFoundWhenRowMissing() {
        when(repo.findById(999L)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.recreateContainer(999L))
                .isInstanceOf(NotFoundException.class);
        verify(provisioner, never()).deprovision(anyString());
        verify(provisioner, never()).provision(any());
    }

    @Test
    void recreateContainerRejectsRestRows() {
        Microservice m = sample(15L);
        m.setKind("REST");
        when(repo.findById(15L)).thenReturn(Optional.of(m));

        assertThatThrownBy(() -> service.recreateContainer(15L))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("kind=QUERY");
        verify(provisioner, never()).deprovision(anyString());
        verify(provisioner, never()).provision(any());
    }
}