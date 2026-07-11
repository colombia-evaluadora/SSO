package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Group;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.GroupRepository;
import com.co.eurekatic.common.repository.UserRepository;
import com.co.eurekatic.ssoadmin.client.SessionInvalidationClient;
import com.co.eurekatic.ssoadmin.dto.GroupRequest;
import com.co.eurekatic.ssoadmin.dto.GroupResponse;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
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
class GroupAdminServiceTest {

    @Mock GroupRepository groupRepository;
    @Mock UserRepository userRepository;
    @Mock SessionInvalidationClient sessionInvalidationClient;
    @InjectMocks GroupAdminService service;

    @Test
    void saveCreatesNewGroupWhenNameDoesNotExist() {
        when(groupRepository.findByName("Ops")).thenReturn(Optional.empty());
        when(groupRepository.save(any(Group.class))).thenAnswer(inv -> {
            Group g = inv.getArgument(0);
            g.setId(7L);
            return g;
        });

        GroupResponse resp = service.save(new GroupRequest(null, "Ops", "Operations team"));

        assertThat(resp.id()).isEqualTo(7L);
        assertThat(resp.name()).isEqualTo("Ops");
        assertThat(resp.description()).isEqualTo("Operations team");
    }

    @Test
    void saveReusesExistingGroupWhenNameAlreadyThere() {
        Group existing = new Group();
        existing.setId(3L);
        existing.setName("Ops");
        existing.setDescription("Old desc");
        when(groupRepository.findByName("Ops")).thenReturn(Optional.of(existing));
        when(groupRepository.save(existing)).thenReturn(existing);

        GroupResponse resp = service.save(new GroupRequest(null, "Ops", "New desc"));

        assertThat(resp.id()).isEqualTo(3L);
        assertThat(resp.description()).isEqualTo("New desc");
    }

    @Test
    void getGroupsReturnsAll() {
        Group g1 = new Group();
        g1.setId(1L);
        g1.setName("A");
        Group g2 = new Group();
        g2.setId(2L);
        g2.setName("B");
        when(groupRepository.findAll()).thenReturn(List.of(g1, g2));

        List<GroupResponse> all = service.getGroups();
        assertThat(all).hasSize(2);
        assertThat(all).extracting(GroupResponse::name).containsExactlyInAnyOrder("A", "B");
    }

    @Test
    void bindUserGroupAddsUser() {
        Group g = new Group();
        g.setId(2L);
        g.setName("Ops");
        User u = new User();
        u.setId(1L);
        u.setEmail("alice");
        when(userRepository.findById(1L)).thenReturn(Optional.of(u));
        when(groupRepository.findById(2L)).thenReturn(Optional.of(g));
        when(groupRepository.save(g)).thenReturn(g);

        service.bindUserGroup(1L, 2L);

        assertThat(g.getUsers()).extracting(User::getEmail).contains("alice");
    }

    @Test
    void bindUserGroupThrowsWhenUserOrGroupMissing() {
        when(userRepository.findById(1L)).thenReturn(Optional.empty());
        assertThatThrownBy(() -> service.bindUserGroup(1L, 2L))
                .isInstanceOf(NotFoundException.class);
    }
}
