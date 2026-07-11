package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.Route;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.common.repository.RouteRepository;
import com.co.eurekatic.ssoadmin.dto.RouteRequest;
import com.co.eurekatic.ssoadmin.dto.RouteResponse;
import com.co.eurekatic.ssoadmin.exception.DuplicateException;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import com.co.eurekatic.ssoadmin.service.RouteService.RoleChecked;
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
class RouteServiceTest {

    @Mock RouteRepository routeRepo;
    @Mock RoleRepository roleRepo;
    @InjectMocks RouteService service;

    private static Route sample(long id) {
        Route r = new Route();
        r.setId(id);
        r.setName("name-" + id);
        r.setPath("/path-" + id);
        r.setMenuOrder(0);
        return r;
    }

    private static Role role(long id, String name) {
        Role r = new Role();
        r.setId(id);
        r.setName(name);
        return r;
    }

    /* ====================== CRUD ====================== */

    @Test
    void createRejectsDuplicateNameAndPath() {
        when(routeRepo.existsByNameAndPath("users", "/users")).thenReturn(true);
        RouteRequest req = new RouteRequest(null, "users", null, "/users", 0, null, null);

        assertThatThrownBy(() -> service.create(req))
                .isInstanceOf(DuplicateException.class)
                .hasMessageContaining("Route");
    }

    @Test
    void createPersistsNewRoute() {
        when(routeRepo.existsByNameAndPath("home", "/home")).thenReturn(false);
        when(routeRepo.save(any(Route.class))).thenAnswer(inv -> {
            Route r = inv.getArgument(0);
            r.setId(1L);
            return r;
        });

        RouteResponse resp = service.create(
                new RouteRequest(null, "home", "icon", "/home", 0, "MENU", null));

        assertThat(resp.id()).isEqualTo(1L);
        assertThat(resp.name()).isEqualTo("home");
        assertThat(resp.icon()).isEqualTo("icon");
        assertThat(resp.type()).isEqualTo("MENU");
    }

    @Test
    void createNormalizesLegacyZeroParentToNull() {
        when(routeRepo.existsByNameAndPath("home", "/home")).thenReturn(false);
        when(routeRepo.save(any(Route.class))).thenAnswer(inv -> inv.getArgument(0));

        RouteResponse resp = service.create(
                new RouteRequest(null, "home", null, "/home", 0, null, 0L));

        assertThat(resp.idParent()).isNull();
    }

    @Test
    void updateRejectsMissingId() {
        assertThatThrownBy(() -> service.update(
                new RouteRequest(null, "x", null, "/x", 0, null, null)))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void updateRejectsDuplicateAgainstOtherRow() {
        Route mine = sample(1L);
        Route other = sample(2L);
        when(routeRepo.findById(1L)).thenReturn(Optional.of(mine));
        when(routeRepo.findByNameAndPath("dup", "/dup")).thenReturn(Optional.of(other));

        assertThatThrownBy(() -> service.update(
                new RouteRequest(1L, "dup", null, "/dup", 0, null, null)))
                .isInstanceOf(DuplicateException.class);
    }

    @Test
    void updateAllowsSameRow() {
        Route mine = sample(1L);
        when(routeRepo.findById(1L)).thenReturn(Optional.of(mine));
        when(routeRepo.findByNameAndPath("name-1", "/path-1")).thenReturn(Optional.of(mine));
        when(routeRepo.save(mine)).thenReturn(mine);

        RouteResponse resp = service.update(
                new RouteRequest(1L, "name-1", null, "/path-1", 0, null, null));

        assertThat(resp.id()).isEqualTo(1L);
    }

    /* ====================== tree queries ====================== */

    @Test
    void getRootsDelegatesToFindByIdParentIsNull() {
        when(routeRepo.findByIdParentIsNull()).thenReturn(List.of(sample(1L), sample(2L)));
        List<RouteResponse> roots = service.getRoots();
        assertThat(roots).extracting(RouteResponse::name)
                .containsExactlyInAnyOrder("name-1", "name-2");
    }

    @Test
    void getChildrenDelegatesToFindByIdParent() {
        when(routeRepo.findByIdParent(1L)).thenReturn(List.of(sample(10L), sample(11L)));
        List<RouteResponse> children = service.getChildren(1L);
        assertThat(children).extracting(RouteResponse::id).containsExactlyInAnyOrder(10L, 11L);
    }

    /* ====================== bindings: role ====================== */

    @Test
    void bindRoleAttaches() {
        Route r = sample(1L);
        Role role = role(5L, "ADMIN");
        when(routeRepo.findById(1L)).thenReturn(Optional.of(r));
        when(roleRepo.findById(5L)).thenReturn(Optional.of(role));
        when(routeRepo.save(r)).thenReturn(r);

        service.bindRole(1L, 5L);

        assertThat(r.getRoles()).extracting(Role::getId).contains(5L);
    }

    @Test
    void bindRoleThrowsWhenRouteMissing() {
        when(routeRepo.findById(1L)).thenReturn(Optional.empty());
        assertThatThrownBy(() -> service.bindRole(1L, 5L))
                .isInstanceOf(NotFoundException.class);
    }

    @Test
    void getRolesForRouteCheckedMarksBound() {
        Route r = sample(1L);
        r.addRole(role(5L, "ADMIN"));
        when(routeRepo.findById(1L)).thenReturn(Optional.of(r));
        when(roleRepo.findAll()).thenReturn(List.of(
                role(5L, "ADMIN"),
                role(6L, "USER")));

        List<RoleChecked> result = service.getRolesForRouteChecked(1L);

        assertThat(result.stream()
                .filter(c -> c.name().equals("ADMIN")).findFirst().orElseThrow().checked())
                .isTrue();
        assertThat(result.stream()
                .filter(c -> c.name().equals("USER")).findFirst().orElseThrow().checked())
                .isFalse();
    }
}
