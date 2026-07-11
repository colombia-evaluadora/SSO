package com.co.eurekatic.auth.security;

import com.co.eurekatic.common.dto.AuthDtos.UserSummary;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.UserRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.security.core.userdetails.UsernameNotFoundException;

import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.when;

/**
 * Unit tests for {@link CachedUserSummaryService}.
 *
 * <p>Exercises the User→UserSummary conversion logic and the
 * {@code UsernameNotFoundException} on unknown email. The
 * {@code @Cacheable} annotation is a Spring proxy concern —
 * these tests exercise the underlying method logic (the real DB
 * call), not the cache intercept. Cache integration is covered
 * by the {@code AuthCenterIntegrationTest}.
 */
@ExtendWith(MockitoExtension.class)
class CachedUserSummaryServiceTest {

    @Mock UserRepository userRepository;
    @InjectMocks CachedUserSummaryService service;

    @Test
    void forEmailReturnsUserSummaryWithRoles() {
        User u = new User("alice@example.com", "password");
        u.setId(5L);
        u.setFullName("Alice");
        u.setEnabled(true);
        u.setLdap(false);
        u.addRole(new Role("ADMIN", null));
        u.addRole(new Role("USER", null));
        when(userRepository.findByEmail("alice@example.com")).thenReturn(Optional.of(u));

        UserSummary summary = service.forEmail("alice@example.com");

        assertThat(summary.id()).isEqualTo(5L);
        assertThat(summary.email()).isEqualTo("alice@example.com");
        assertThat(summary.fullName()).isEqualTo("Alice");
        assertThat(summary.enabled()).isTrue();
        assertThat(summary.ldap()).isFalse();
        assertThat(summary.roles()).containsExactlyInAnyOrder("ADMIN", "USER");
    }

    @Test
    void forEmailThrowsForUnknownEmail() {
        when(userRepository.findByEmail("ghost@example.com")).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.forEmail("ghost@example.com"))
                .isInstanceOf(UsernameNotFoundException.class)
                .hasMessageContaining("ghost@example.com");
    }

    @Test
    void forEmailReturnsEmptyRolesForUserWithNoRoles() {
        User u = new User("nobody@example.com", "password");
        u.setId(99L);
        u.setEnabled(false);
        u.setLdap(true);
        when(userRepository.findByEmail("nobody@example.com")).thenReturn(Optional.of(u));

        UserSummary summary = service.forEmail("nobody@example.com");

        assertThat(summary.id()).isEqualTo(99L);
        assertThat(summary.roles()).isEmpty();
        assertThat(summary.ldap()).isTrue();
        assertThat(summary.enabled()).isFalse();
    }
}
