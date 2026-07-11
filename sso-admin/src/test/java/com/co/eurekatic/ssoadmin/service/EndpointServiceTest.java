package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Endpoint;
import com.co.eurekatic.common.entity.Microservice;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.repository.EndpointRepository;
import com.co.eurekatic.common.repository.MicroserviceRepository;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.ssoadmin.dto.EndpointRequest;
import com.co.eurekatic.ssoadmin.dto.EndpointResponse;
import com.co.eurekatic.ssoadmin.exception.DuplicateException;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import com.co.eurekatic.ssoadmin.service.EndpointService.MicroserviceChecked;
import com.co.eurekatic.ssoadmin.service.EndpointService.RoleChecked;
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
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class EndpointServiceTest {

    @Mock EndpointRepository endpointRepo;
    @Mock MicroserviceRepository microserviceRepo;
    @Mock RoleRepository roleRepo;
    @InjectMocks EndpointService service;

    private static Endpoint sample(long id) {
        Endpoint e = new Endpoint();
        e.setId(id);
        e.setMethod("GET");
        e.setPath("/api/things");
        e.setDescription("List things");
        e.setNumberParams(0);
        return e;
    }

    private static Microservice microservice(long id, String serviceId) {
        Microservice m = new Microservice();
        m.setId(id);
        m.setServiceId(serviceId);
        return m;
    }

    private static Role role(long id, String name) {
        Role r = new Role();
        r.setId(id);
        r.setName(name);
        return r;
    }

    /* ====================== CRUD ====================== */

    @Test
    void createRejectsDuplicatePathMethodDescription() {
        when(endpointRepo.existsByPathAndMethodAndDescription("/x", "GET", "d")).thenReturn(true);
        EndpointRequest req = new EndpointRequest(null, "GET", "/x", "d", 0);

        assertThatThrownBy(() -> service.create(req))
                .isInstanceOf(DuplicateException.class)
                .hasMessageContaining("Endpoint");
    }

    @Test
    void createPersistsNewEndpoint() {
        when(endpointRepo.existsByPathAndMethodAndDescription("/x", "POST", "d")).thenReturn(false);
        when(endpointRepo.save(any(Endpoint.class))).thenAnswer(inv -> {
            Endpoint e = inv.getArgument(0);
            e.setId(11L);
            return e;
        });

        EndpointResponse resp = service.create(new EndpointRequest(null, "POST", "/x", "d", 1));

        assertThat(resp.id()).isEqualTo(11L);
        assertThat(resp.method()).isEqualTo("POST");
        assertThat(resp.numberParams()).isEqualTo(1);
    }

    @Test
    void createDefaultsNumberParamsToZeroWhenNull() {
        when(endpointRepo.existsByPathAndMethodAndDescription("/x", "GET", "d")).thenReturn(false);
        when(endpointRepo.save(any(Endpoint.class))).thenAnswer(inv -> inv.getArgument(0));

        EndpointResponse resp = service.create(new EndpointRequest(null, "GET", "/x", "d", null));

        assertThat(resp.numberParams()).isEqualTo(0);
    }

    @Test
    void updateRejectsMissingId() {
        assertThatThrownBy(() -> service.update(new EndpointRequest(null, "GET", "/x", "d", 0)))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void updateRejectsDuplicateAgainstOtherRow() {
        Endpoint mine = sample(1L);
        Endpoint other = sample(2L);
        when(endpointRepo.findById(1L)).thenReturn(Optional.of(mine));
        when(endpointRepo.findByPathAndMethodAndDescription("/x", "GET", "d"))
                .thenReturn(Optional.of(other));

        EndpointRequest req = new EndpointRequest(1L, "GET", "/x", "d", 0);

        assertThatThrownBy(() -> service.update(req))
                .isInstanceOf(DuplicateException.class);
    }

    @Test
    void updateAllowsSameRow() {
        Endpoint mine = sample(1L);
        when(endpointRepo.findById(1L)).thenReturn(Optional.of(mine));
        when(endpointRepo.findByPathAndMethodAndDescription("/api/things", "GET", "List things"))
                .thenReturn(Optional.of(mine));
        when(endpointRepo.save(mine)).thenReturn(mine);

        EndpointResponse resp = service.update(
                new EndpointRequest(1L, "GET", "/api/things", "List things", 0));

        assertThat(resp.id()).isEqualTo(1L);
    }

    /* ====================== bindings: microservice ====================== */

    @Test
    void bindMicroserviceAttaches() {
        Endpoint e = sample(1L);
        Microservice m = microservice(2L, "svc");
        when(endpointRepo.findById(1L)).thenReturn(Optional.of(e));
        when(microserviceRepo.findById(2L)).thenReturn(Optional.of(m));
        when(endpointRepo.save(e)).thenReturn(e);

        service.bindMicroservice(1L, 2L);

        assertThat(e.getMicroservices()).extracting(Microservice::getId).contains(2L);
    }

    @Test
    void bindMicroserviceThrowsWhenEndpointMissing() {
        when(endpointRepo.findById(1L)).thenReturn(Optional.empty());
        assertThatThrownBy(() -> service.bindMicroservice(1L, 2L))
                .isInstanceOf(NotFoundException.class);
    }

    @Test
    void bindMicroserviceThrowsWhenMicroserviceMissing() {
        Endpoint e = sample(1L);
        when(endpointRepo.findById(1L)).thenReturn(Optional.of(e));
        when(microserviceRepo.findById(2L)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.bindMicroservice(1L, 2L))
                .isInstanceOf(NotFoundException.class);
    }

    @Test
    void getMicroservicesForEndpointCheckedMarksBound() {
        Endpoint e = sample(1L);
        e.addMicroservice(microservice(2L, "bound"));
        when(endpointRepo.findById(1L)).thenReturn(Optional.of(e));
        when(microserviceRepo.findAll()).thenReturn(List.of(
                microservice(2L, "bound"),
                microservice(3L, "unbound")));

        List<MicroserviceChecked> result = service.getMicroservicesForEndpointChecked(1L);

        assertThat(result).hasSize(2);
        assertThat(result.stream()
                .filter(c -> c.serviceId().equals("bound")).findFirst().orElseThrow().checked())
                .isTrue();
        assertThat(result.stream()
                .filter(c -> c.serviceId().equals("unbound")).findFirst().orElseThrow().checked())
                .isFalse();
    }

    /* ====================== bindings: role ====================== */

    @Test
    void bindRoleAttaches() {
        Endpoint e = sample(1L);
        Role r = role(5L, "ADMIN");
        when(endpointRepo.findById(1L)).thenReturn(Optional.of(e));
        when(roleRepo.findById(5L)).thenReturn(Optional.of(r));
        when(endpointRepo.save(e)).thenReturn(e);

        service.bindRole(1L, 5L);

        assertThat(e.getRoles()).extracting(Role::getId).contains(5L);
    }

    @Test
    void unbindRoleDetaches() {
        Endpoint e = sample(1L);
        Role r = role(5L, "ADMIN");
        e.addRole(r);
        when(endpointRepo.findById(1L)).thenReturn(Optional.of(e));
        when(roleRepo.findById(5L)).thenReturn(Optional.of(r));
        when(endpointRepo.save(e)).thenReturn(e);

        service.unbindRole(1L, 5L);

        assertThat(e.getRoles()).isEmpty();
    }

    @Test
    void getRolesForEndpointCheckedMarksBound() {
        Endpoint e = sample(1L);
        e.addRole(role(5L, "ADMIN"));
        when(endpointRepo.findById(1L)).thenReturn(Optional.of(e));
        when(roleRepo.findAll()).thenReturn(List.of(
                role(5L, "ADMIN"),
                role(6L, "USER")));

        List<RoleChecked> result = service.getRolesForEndpointChecked(1L);

        assertThat(result).hasSize(2);
        assertThat(result.stream().filter(c -> c.name().equals("ADMIN")).findFirst().orElseThrow().checked()).isTrue();
        assertThat(result.stream().filter(c -> c.name().equals("USER")).findFirst().orElseThrow().checked()).isFalse();
    }
}
