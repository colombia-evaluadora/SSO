package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.common.repository.UserRepository;
import com.co.eurekatic.ssoadmin.client.SessionInvalidationClient;
import com.co.eurekatic.ssoadmin.config.EmailProperties;
import com.co.eurekatic.ssoadmin.dto.CreateAccountRequest;
import com.co.eurekatic.ssoadmin.dto.UpdateAccountRequest;
import com.co.eurekatic.ssoadmin.dto.UserResponse;
import com.co.eurekatic.ssoadmin.event.NotificationEventPublisher;
import com.co.eurekatic.ssoadmin.exception.EmailInvalidException;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import com.co.eurekatic.ssoadmin.exception.UserDuplicateException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.cache.CacheManager;
import org.springframework.security.crypto.password.PasswordEncoder;

import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Unit tests for {@link UserAdminService}. All collaborators
 * (repos, password encoder, TokenService, EmailService,
 * NotificationEventPublisher) are mocked — the goal is to verify
 * the business rules in isolation, not the JPA layer (covered by
 * the integration test).
 *
 * <p>Post-V12, the {@code username} column is gone; the create
 * and update flows operate on email + numeric {@code id}
 * respectively. All references here match that model.
 */
@ExtendWith(MockitoExtension.class)
class UserAdminServiceTest {

    @Mock UserRepository userRepository;
    @Mock RoleRepository roleRepository;
    @Mock PasswordEncoder passwordEncoder;
    @Mock TokenService tokenService;
    @Mock EmailService emailService;
    @Mock NotificationEventPublisher events;
    @Mock SessionInvalidationClient sessionInvalidationClient;
    @Mock CacheManager cacheManager;

    UserAdminService service;

    private Role adminRole;

    private static final String ALICE_EMAIL = "alice@example.com";

    @BeforeEach
    void setUp() {
        adminRole = new Role("ADMIN", "Administrator");
        // EmailProperties is a Spring-bound record; tests don't
        // load application.yml, so we wire the URLs the service
        // needs for activation/restore password tokens. Field
        // order: from, company, appName, logoUrl, activationUrl,
        // restoreUrl, activationTemplate, restoreTemplate.
        EmailProperties emailProps = new EmailProperties(
                "no-reply@example.com",
                "Acme",
                "SSO",
                "https://example.com/logo.png",
                "http://localhost/admin/activate",
                "http://localhost/admin/restore-password",
                "activation-account.html",
                "restore-password-account.html");
        service = new UserAdminService(userRepository, roleRepository,
                passwordEncoder, tokenService, emailService,
                emailProps, events, sessionInvalidationClient, cacheManager);
    }

    /* ====================== createAccount ====================== */

    @Test
    void createAccountRejectsDuplicateEmail() {
        when(userRepository.existsByEmail(ALICE_EMAIL)).thenReturn(true);

        CreateAccountRequest req = new CreateAccountRequest(
                "Alice", ALICE_EMAIL, List.of());

        assertThatThrownBy(() -> service.createAccount(req))
                .isInstanceOf(UserDuplicateException.class)
                .hasMessageContaining(ALICE_EMAIL);
        verify(userRepository, never()).save(any());
    }

    @Test
    void createAccountRejectsInvalidEmail() {
        // No when() — the email-format check runs BEFORE the
        // existsByEmail call, so a strict stub on the repository
        // would trip UnnecessaryStubbingException.
        CreateAccountRequest req = new CreateAccountRequest(
                "Alice", "not-an-email", List.of());

        assertThatThrownBy(() -> service.createAccount(req))
                .isInstanceOf(EmailInvalidException.class);
    }

    @Test
    void createAccountSucceedsAndSendsActivationEmail() {
        when(userRepository.existsByEmail(ALICE_EMAIL)).thenReturn(false);
        when(tokenService.issueActivationToken(any(User.class))).thenReturn("tok-123");
        when(userRepository.save(any(User.class))).thenAnswer(inv -> {
            User u = inv.getArgument(0);
            u.setId(7L);
            return u;
        });

        CreateAccountRequest req = new CreateAccountRequest(
                "Alice Example", ALICE_EMAIL, List.of("ADMIN"));

        when(roleRepository.findByName("ADMIN")).thenReturn(Optional.of(adminRole));

        UserResponse resp = service.createAccount(req);

        assertThat(resp.id()).isEqualTo(7L);
        assertThat(resp.email()).isEqualTo(ALICE_EMAIL);
        assertThat(resp.roleNames()).containsExactly("ADMIN");

        // createAccount does NOT encode a password — that's
        // activateAccount's job. Encoding here would be a leak
        // of the admin's eventual obligation onto a code path
        // that shouldn't be touching the encoder at all.
        verify(passwordEncoder, never()).encode(anyString());

        // Token must be issued exactly once, and the activation
        // event is published via NotificationEventPublisher
        // (notification-service renders + sends the email).
        verify(tokenService, times(1)).issueActivationToken(any(User.class));
        verify(emailService, never()).sendActivationEmail(any(), anyString());
        verify(events).publish(
                eq("email"),
                eq("7"),
                eq(ALICE_EMAIL),
                eq("account-activation"),
                any(),
                any());
    }

    @Test
    void createAccountSkipsRoleLookupWhenRoleListEmpty() {
        when(userRepository.existsByEmail(ALICE_EMAIL)).thenReturn(false);
        when(tokenService.issueActivationToken(any())).thenReturn("tok");
        when(userRepository.save(any())).thenAnswer(inv -> inv.getArgument(0));

        CreateAccountRequest req = new CreateAccountRequest(
                "Alice", ALICE_EMAIL, List.of());

        UserResponse resp = service.createAccount(req);

        assertThat(resp.roleNames()).isEmpty();
        verify(roleRepository, never()).findByName(anyString());
    }

    @Test
    void createAccountLeavesPasswordNullUntilActivation() {
        // The user.password column is intentionally null right
        // after createAccount — activation (POST /activateAccount
        // → UserAdminService.activateAccount) is the only path
        // that ever BCrypts and stamps it. Pin the behaviour so
        // no future refactor quietly re-adds an admin-typed
        // password.
        when(userRepository.existsByEmail(ALICE_EMAIL)).thenReturn(false);
        when(tokenService.issueActivationToken(any())).thenReturn("tok");
        when(userRepository.save(any())).thenAnswer(inv -> {
            User u = inv.getArgument(0);
            u.setId(7L);
            return u;
        });

        CreateAccountRequest req = new CreateAccountRequest(
                "Alice", ALICE_EMAIL, List.of());

        service.createAccount(req);

        // Capture the entity that createAccount was about to save
        // and assert the password column was left null.
        ArgumentCaptor<User> saved =
                ArgumentCaptor.forClass(User.class);
        verify(userRepository).save(saved.capture());
        assertThat(saved.getValue().getPassword()).isNull();
        verify(passwordEncoder, never()).encode(anyString());
    }

    /* ====================== updateAccount ====================== */

    @Test
    void updateAccountRejectsUnknownUser() {
        when(userRepository.findById(999L)).thenReturn(Optional.empty());

        UpdateAccountRequest req = new UpdateAccountRequest(
                /* id */ 999L, "New", null, null, null, null);

        assertThatThrownBy(() -> service.updateAccount(req))
                .isInstanceOf(NotFoundException.class);
    }

    @Test
    void updateAccountAppliesNonNullFieldsAndReplacesRoles() {
        User existing = new User();
        existing.setId(7L);
        existing.setEmail("old@example.com");
        existing.setFullName("Old Name");
        existing.setActive(true);
        existing.addRole(adminRole);

        when(userRepository.findById(7L)).thenReturn(Optional.of(existing));
        when(userRepository.save(any(User.class))).thenAnswer(inv -> inv.getArgument(0));

        Role userRole = new Role("USER", "regular");
        when(roleRepository.findByName("USER")).thenReturn(Optional.of(userRole));

        UpdateAccountRequest req = new UpdateAccountRequest(
                /* id */ 7L, "New Name", "new@example.com", false, null, List.of("USER"));

        UserResponse resp = service.updateAccount(req);

        assertThat(resp.fullName()).isEqualTo("New Name");
        assertThat(resp.email()).isEqualTo("new@example.com");
        assertThat(resp.active()).isFalse();
        // Roles replaced: ADMIN removed, USER added.
        assertThat(resp.roleNames()).containsExactly("USER");

        // The original Set was mutated in place, not reassigned.
        assertThat(existing.getRoles()).extracting(Role::getName)
                .containsExactly("USER");
    }

    @Test
    void updateAccountWithNullRoleNamesLeavesRolesUntouched() {
        User existing = new User();
        existing.setId(7L);
        existing.setEmail("alice@example.com");
        existing.addRole(adminRole);
        when(userRepository.findById(7L)).thenReturn(Optional.of(existing));
        when(userRepository.save(any())).thenAnswer(inv -> inv.getArgument(0));

        UpdateAccountRequest req = new UpdateAccountRequest(
                /* id */ 7L, null, null, null, null, null);

        UserResponse resp = service.updateAccount(req);
        assertThat(resp.roleNames()).containsExactly("ADMIN");
        verify(roleRepository, never()).findByName(anyString());
    }

    /* ====================== activateAccount ====================== */

    @Test
    void activateAccountRejectsShortPassword() {
        assertThatThrownBy(() -> service.activateAccount("tok", "123"))
                .isInstanceOf(IllegalArgumentException.class);
        verify(tokenService, never()).consumeActivationToken(anyString());
    }

    @Test
    void activateAccountEncodesPasswordAndEnablesUser() {
        User u = new User();
        u.setEmail("alice@example.com");
        u.setActive(false);
        u.setEnabled(false);
        when(tokenService.consumeActivationToken("tok")).thenReturn(u);
        when(passwordEncoder.encode("newpass1")).thenReturn("$2a$hashed");
        when(userRepository.save(any())).thenAnswer(inv -> inv.getArgument(0));

        service.activateAccount("tok", "newpass1");

        assertThat(u.isEnabled()).isTrue();
        assertThat(u.isActive()).isTrue();
        assertThat(u.getPassword()).isEqualTo("$2a$hashed");
    }

    /* ====================== forgotPassword ====================== */

    @Test
    void forgotPasswordIsNoOpWhenEmailUnknown() {
        when(userRepository.findAll()).thenReturn(List.of());

        // Should NOT throw — legacy would have failed noisily.
        service.forgotPassword("nobody@example.com");

        verify(emailService, never()).sendRestorePasswordEmail(any(), anyString());
        verify(tokenService, never()).issueRestoreToken(any());
    }

    @Test
    void forgotPasswordIssuesTokenAndEmailsWhenKnown() {
        User u = new User();
        u.setEmail("alice@example.com");
        when(userRepository.findAll()).thenReturn(List.of(u));
        when(tokenService.issueRestoreToken(u)).thenReturn("rtok");
        when(userRepository.save(u)).thenReturn(u);

        service.forgotPassword("alice@example.com");

        // Restore-token must be issued, and the password-reset event
        // is published via NotificationEventPublisher with the token
        // embedded in the payload's resetLink.
        verify(tokenService, times(1)).issueRestoreToken(u);
        verify(emailService, never()).sendRestorePasswordEmail(any(), anyString());
        @SuppressWarnings("unchecked")
        ArgumentCaptor<Map<String, Object>> payload =
                ArgumentCaptor.forClass(Map.class);
        verify(events).publish(
                eq("email"),
                anyString(),
                eq("alice@example.com"),
                eq("password-reset"),
                payload.capture(),
                any());
        Map<String, Object> p = payload.getValue();
        assertThat(p.get("resetLink").toString()).contains("rtok");
    }

    /* ====================== getRolesByEmail ====================== */

    @Test
    void getRolesByEmailReturnsNamesList() {
        User u = new User();
        u.setEmail("alice@example.com");
        u.addRole(new Role("ADMIN", null));
        u.addRole(new Role("USER", null));
        when(userRepository.findByEmail("alice@example.com")).thenReturn(Optional.of(u));

        List<String> roles = service.getRolesByEmail("alice@example.com");

        assertThat(roles).containsExactlyInAnyOrder("ADMIN", "USER");
    }

    @Test
    void getRolesByEmailThrowsWhenMissing() {
        when(userRepository.findByEmail("ghost@example.com")).thenReturn(Optional.empty());
        assertThatThrownBy(() -> service.getRolesByEmail("ghost@example.com"))
                .isInstanceOf(NotFoundException.class);
    }

    /* ====================== bind / unbind ====================== */

    @Test
    void bindUserRoleAddsRole() {
        User u = new User();
        u.setId(1L);
        Role r = new Role();
        r.setId(2L);
        r.setName("ADMIN");
        when(userRepository.findById(1L)).thenReturn(Optional.of(u));
        when(roleRepository.findById(2L)).thenReturn(Optional.of(r));
        when(userRepository.save(u)).thenReturn(u);

        service.bindUserRole(1L, 2L);

        assertThat(u.getRoles()).extracting(Role::getName).contains("ADMIN");
    }

    @Test
    void unbindUserRoleIsNoOpWhenRoleNotPresent() {
        User u = new User();
        u.setId(1L);
        Role userRole = new Role("USER", null);
        userRole.setId(5L);
        u.addRole(userRole);
        when(userRepository.findById(1L)).thenReturn(Optional.of(u));
        when(userRepository.save(u)).thenReturn(u);

        // No role with id 99L on the user — must not throw.
        service.unbindUserRole(1L, 99L);

        assertThat(u.getRoles()).extracting(Role::getName).containsExactly("USER");
    }

    /* ====================== helpers ====================== */

    private static <T> T eq(T value) {
        return org.mockito.ArgumentMatchers.eq(value);
    }
}
