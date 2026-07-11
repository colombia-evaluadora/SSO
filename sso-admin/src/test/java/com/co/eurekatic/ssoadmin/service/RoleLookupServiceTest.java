package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.repository.RoleRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.when;

/**
 * Unit tests for {@link RoleLookupService}.
 *
 * <p>Verifies the name→id map construction and the convenience
 * {@code nameToIdFiltered} method. The {@code @Cacheable}
 * annotation is a Spring proxy concern — these tests exercise the
 * underlying method logic (the real DB call), not the cache
 * intercept. Cache integration is covered by the
 * {@code SsoAdminIntegrationTest}.
 */
@ExtendWith(MockitoExtension.class)
class RoleLookupServiceTest {

    @Mock RoleRepository roleRepository;
    @InjectMocks RoleLookupService service;

    @Test
    void nameToIdReturnsMapOfAllRoles() {
        Role admin = new Role("ADMIN", "Administrator");
        admin.setId(1L);
        Role analyst = new Role("ANALYST", "Read only");
        analyst.setId(2L);
        when(roleRepository.findAll()).thenReturn(List.of(admin, analyst));

        Map<String, Long> result = service.nameToId();

        assertThat(result).containsExactlyInAnyOrderEntriesOf(Map.of(
                "ADMIN", 1L,
                "ANALYST", 2L));
    }

    @Test
    void nameToIdReturnsEmptyMapWhenNoRoles() {
        when(roleRepository.findAll()).thenReturn(List.of());

        Map<String, Long> result = service.nameToId();

        assertThat(result).isEmpty();
    }

    @Test
    void nameToIdFilteredReturnsOnlyMatchingRoles() {
        Role admin = new Role("ADMIN", null);
        admin.setId(1L);
        Role analyst = new Role("ANALYST", null);
        analyst.setId(2L);
        Role user = new Role("USER", null);
        user.setId(3L);
        when(roleRepository.findAll()).thenReturn(List.of(admin, analyst, user));

        Map<String, Long> result = service.nameToIdFiltered(Set.of("ADMIN", "USER"));

        assertThat(result).containsExactly(
                Map.entry("ADMIN", 1L),
                Map.entry("USER", 3L));
    }

    @Test
    void nameToIdFilteredReturnsEmptyMapWhenNoOverlap() {
        Role admin = new Role("ADMIN", null);
        admin.setId(1L);
        when(roleRepository.findAll()).thenReturn(List.of(admin));

        Map<String, Long> result = service.nameToIdFiltered(Set.of("GHOST"));

        assertThat(result).isEmpty();
    }

    @Test
    void nameToIdFilteredReturnsEmptyMapForNullInput() {
        assertThat(service.nameToIdFiltered(null)).isEmpty();
    }

    @Test
    void nameToIdFilteredReturnsEmptyMapForEmptyInput() {
        assertThat(service.nameToIdFiltered(Set.of())).isEmpty();
    }
}
