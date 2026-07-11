package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.common.repository.UserRepository;
import com.co.eurekatic.ssoadmin.dto.RoleRequest;
import com.co.eurekatic.ssoadmin.dto.RoleResponse;
import com.co.eurekatic.ssoadmin.dto.UserResponse;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import com.co.eurekatic.ssoadmin.service.RoleAdminService.UserRoleChecked;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.cache.CacheManager;

import java.util.List;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class RoleAdminServiceTest {

    @Mock RoleRepository roleRepository;
    @Mock UserRepository userRepository;
    @Mock CacheManager cacheManager;
    @InjectMocks RoleAdminService service;

    @Test
    void createRoleRejectsDuplicateName() {
        when(roleRepository.existsByName("ADMIN")).thenReturn(true);
        RoleRequest req = new RoleRequest(null, "ADMIN", "Administrator");

        assertThatThrownBy(() -> service.createRole(req))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("ADMIN");
    }

    @Test
    void createRolePersistsNewRole() {
        when(roleRepository.existsByName("AUDITOR")).thenReturn(false);
        when(roleRepository.save(any(Role.class))).thenAnswer(inv -> {
            Role r = inv.getArgument(0);
            r.setId(11L);
            return r;
        });

        RoleResponse resp = service.createRole(new RoleRequest(null, "AUDITOR", "Read only"));

        assertThat(resp.id()).isEqualTo(11L);
        assertThat(resp.name()).isEqualTo("AUDITOR");
        assertThat(resp.description()).isEqualTo("Read only");
    }

    @Test
    void updateRoleRejectsMissingId() {
        RoleRequest req = new RoleRequest(null, "X", "y");
        assertThatThrownBy(() -> service.updateRole(req))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void updateRoleThrowsWhenRoleMissing() {
        when(roleRepository.findById(99L)).thenReturn(java.util.Optional.empty());
        RoleRequest req = new RoleRequest(99L, "X", "y");
        assertThatThrownBy(() -> service.updateRole(req))
                .isInstanceOf(NotFoundException.class);
    }

    @Test
    void updateRoleAppliesNameAndDescription() {
        Role r = new Role("OLD", "old desc");
        r.setId(5L);
        when(roleRepository.findById(5L)).thenReturn(java.util.Optional.of(r));
        when(roleRepository.save(r)).thenReturn(r);

        RoleResponse resp = service.updateRole(new RoleRequest(5L, "NEW", "new desc"));

        assertThat(resp.name()).isEqualTo("NEW");
        assertThat(resp.description()).isEqualTo("new desc");
    }

    @Test
    void getRolesOwnExcludesAdminUsuariosOperadoras() {
        Role admin = new Role("ADMIN", null);
        Role adminOp = new Role("ADMIN_USUARIOS_OPERADORAS", null);
        Role user = new Role("USER", null);
        when(roleRepository.findAll()).thenReturn(List.of(admin, adminOp, user));

        List<RoleResponse> result = service.getRolesOwn();

        assertThat(result).extracting(RoleResponse::name)
                .containsExactlyInAnyOrder("ADMIN", "USER")
                .doesNotContain("ADMIN_USUARIOS_OPERADORAS");
    }

    @Test
    void getUsersForRoleReturnsMembers() {
        Role r = new Role();
        r.setId(1L);
        User u = new User();
        u.setId(10L);
        u.setEmail("alice");
        u.setFullName("Alice");
        r.getUsers().add(u);
        when(roleRepository.findById(1L)).thenReturn(java.util.Optional.of(r));

        List<UserResponse> users = service.getUsersForRole(1L);
        assertThat(users).hasSize(1);
        assertThat(users.get(0).email()).isEqualTo("alice");
    }

    @Test
    void getUsersForRoleCheckedMarksMembers() {
        Role r = new Role();
        r.setId(1L);
        r.setName("ADMIN");
        User member = new User();
        member.setId(10L);
        member.setEmail("alice");
        member.setFullName("Alice");
        User nonMember = new User();
        nonMember.setId(11L);
        nonMember.setEmail("bob");
        nonMember.setFullName("Bob");
        r.getUsers().add(member);
        when(roleRepository.findById(1L)).thenReturn(java.util.Optional.of(r));
        when(userRepository.findAll()).thenReturn(List.of(member, nonMember));

        List<UserRoleChecked> result = service.getUsersForRoleChecked(1L);

        assertThat(result).hasSize(2);
        UserRoleChecked aliceRow = result.stream()
                .filter(c -> c.email().equals("alice")).findFirst().orElseThrow();
        UserRoleChecked bobRow = result.stream()
                .filter(c -> c.email().equals("bob")).findFirst().orElseThrow();
        assertThat(aliceRow.checked()).isTrue();
        assertThat(bobRow.checked()).isFalse();
    }

    @Test
    void getUsersForRoleThrowsWhenRoleMissing() {
        when(roleRepository.findById(99L)).thenReturn(java.util.Optional.empty());
        assertThatThrownBy(() -> service.getUsersForRole(99L))
                .isInstanceOf(NotFoundException.class);
    }
}
