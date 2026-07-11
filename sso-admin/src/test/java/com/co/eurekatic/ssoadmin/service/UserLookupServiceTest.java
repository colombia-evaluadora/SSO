package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.UserRepository;
import com.co.eurekatic.ssoadmin.service.UserLookupService.UserRolesView;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.when;

/**
 * Unit tests for {@link UserLookupService}.
 *
 * <p>Verifies the User→UserRolesView projection and the EMPTY
 * sentinel for unknown users. The {@code @Cacheable} annotation
 * is a Spring proxy concern — these tests exercise the underlying
 * method logic (the real DB call), not the cache intercept.
 */
@ExtendWith(MockitoExtension.class)
class UserLookupServiceTest {

    @Mock UserRepository userRepository;
    @InjectMocks UserLookupService service;

    @Test
    void rolesForReturnsViewWithRoleNames() {
        User u = new User("alice@example.com", "Alice");
        u.setId(5L);
        Role admin = new Role("ADMIN", null);
        Role analyst = new Role("ANALYST", null);
        u.addRole(admin);
        u.addRole(analyst);
        when(userRepository.findByEmail("alice@example.com")).thenReturn(Optional.of(u));

        UserRolesView view = service.rolesFor("alice@example.com");

        assertThat(view.id()).isEqualTo(5L);
        assertThat(view.email()).isEqualTo("alice@example.com");
        assertThat(view.roles()).containsExactlyInAnyOrder("ADMIN", "ANALYST");
    }

    @Test
    void rolesForReturnsEmptyViewForUnknownEmail() {
        when(userRepository.findByEmail("ghost@example.com")).thenReturn(Optional.empty());

        UserRolesView view = service.rolesFor("ghost@example.com");

        assertThat(view).isEqualTo(UserRolesView.EMPTY);
    }

    @Test
    void rolesForReturnsViewWithEmptyRolesForUserWithNoRoles() {
        User u = new User("nobody@example.com", "Nobody");
        u.setId(99L);
        when(userRepository.findByEmail("nobody@example.com")).thenReturn(Optional.of(u));

        UserRolesView view = service.rolesFor("nobody@example.com");

        assertThat(view.id()).isEqualTo(99L);
        assertThat(view.roles()).isEmpty();
    }

    @Test
    void hasRoleReturnsTrueForMatchingRole() {
        UserRolesView view = new UserRolesView(1L, "x@x.com", Set.of("ADMIN", "USER"));

        assertThat(view.hasRole("ADMIN")).isTrue();
        assertThat(view.hasRole("USER")).isTrue();
    }

    @Test
    void hasRoleReturnsFalseForNonMatchingRole() {
        UserRolesView view = new UserRolesView(1L, "x@x.com", Set.of("USER"));

        assertThat(view.hasRole("ADMIN")).isFalse();
    }

    @Test
    void emptyViewHasNoRole() {
        assertThat(UserRolesView.EMPTY.hasRole("ADMIN")).isFalse();
    }

    @Test
    void ofNullableReturnsEmptyForNullAndEmptySentinel() {
        assertThat(UserRolesView.ofNullable(null)).isEmpty();
        assertThat(UserRolesView.ofNullable(UserRolesView.EMPTY)).isEmpty();
    }

    @Test
    void ofNullableReturnsPresentForValidView() {
        UserRolesView view = new UserRolesView(1L, "x@x.com", Set.of("ADMIN"));
        assertThat(UserRolesView.ofNullable(view)).isPresent();
    }
}
