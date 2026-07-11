package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Group;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.repository.GroupRepository;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.common.repository.UserRepository;
import com.co.eurekatic.ssoadmin.client.SessionInvalidationClient;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class GroupAdminServiceRolesTest {

    @Mock GroupRepository groupRepository;
    @Mock UserRepository userRepository;
    @Mock RoleRepository roleRepository;
    @Mock SessionInvalidationClient sessionInvalidationClient;
    @InjectMocks GroupAdminService service;

    @Test
    void bindRoleThenCheckedReflectsIt() {
        Group group = new Group();
        group.setId(2L);
        group.setName("Ops");

        Role roleA = new Role();
        roleA.setId(10L);
        roleA.setName("ROLE_A");

        Role roleB = new Role();
        roleB.setId(20L);
        roleB.setName("ROLE_B");

        when(groupRepository.findById(2L)).thenReturn(Optional.of(group));
        when(roleRepository.findById(10L)).thenReturn(Optional.of(roleA));
        when(groupRepository.save(group)).thenReturn(group);
        when(roleRepository.findAll()).thenReturn(List.of(roleA, roleB));

        service.bindRole(2L, 10L);

        var checked = service.getRolesForGroupChecked(2L);

        assertThat(checked)
                .extracting(GroupAdminService.RoleChecked::checked)
                .containsExactlyInAnyOrder(true, false);
    }
}
