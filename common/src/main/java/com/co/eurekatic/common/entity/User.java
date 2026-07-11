package com.co.eurekatic.common.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.JoinTable;
import jakarta.persistence.ManyToMany;
import jakarta.persistence.Table;
import lombok.AccessLevel;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.userdetails.UserDetails;

import java.time.Instant;
import java.util.Collection;
import java.util.HashSet;
import java.util.Objects;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * User entity. Implements {@link UserDetails} so auth-center can return it
 * directly from its {@code UserDetailsService.loadUserByUsername(...)} call.
 *
 * <p>Modernized version of the legacy {@code com.co.lowcode.lineabase.model.User}:
 * uses {@code jakarta.persistence.*} (not {@code javax.*}), uses
 * {@code Set<Role>} for the role relation (not the legacy collection
 * anti-pattern), and exposes a clean {@link UserDetails} surface.
 *
 * <h2>Login identifier</h2>
 * <p>The login identifier is now {@link #email} (see Flyway migration
 * {@code V12}). The {@code username} column is gone — callers should
 * use {@link #getEmail()} instead. {@link #getUsername()} is kept only
 * to satisfy the {@link UserDetails} contract; it returns {@code email}
 * because Spring Security treats it as an opaque principal name.
 *
 * <p>Schema mirrors the legacy DB:
 * <ul>
 *   <li>table: {@code users}</li>
 *   <li>id column: {@code id_user}</li>
 *   <li>login identifier: {@code email} (UNIQUE, NOT NULL since V12)</li>
 *   <li>role join table: {@code role_users} (matches legacy)</li>
 * </ul>
 */
@Entity
@Table(name = "users")
@Getter
@Setter
@NoArgsConstructor
public class User implements UserDetails {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "id_user")
    private Long id;

    @Column(name = "full_name", length = 200)
    private String fullName;

    /**
     * Login identifier. UNIQUE + NOT NULL (enforced by the V12
     * migration). Spring's {@link #getUsername()} returns this
     * field so the {@link UserDetails} contract stays satisfied.
     */
    @Column(name = "email", nullable = false, unique = true, length = 200)
    private String email;

    /**
     * BCrypt-hashed password. Never store plaintext. Length 68 to fit a
     * standard 60-char BCrypt hash with breathing room.
     */
    @Column(name = "password", length = 68)
    private String password;

    @Column(name = "enabled", nullable = false)
    private boolean enabled = true;

    @Column(name = "account_non_expired", nullable = false)
    private boolean accountNonExpired = true;

    @Column(name = "account_non_locked", nullable = false)
    private boolean accountNonLocked = true;

    @Column(name = "credentials_non_expired", nullable = false)
    private boolean credentialsNonExpired = true;

    /**
     * Legacy-compatible flag: indicates the user is provisioned but not yet
     * activated (e.g. has not set a password). Mirrors the legacy
     * {@code ACTIVE} column.
     */
    @Column(name = "active", nullable = false)
    private boolean active = true;

    /**
     * Legacy-compatible flag: indicates the user is authenticated via LDAP
     * rather than the local password table.
     */
    @Column(name = "ldap", nullable = false)
    private boolean ldap = false;

    @Column(name = "refresh_token", length = 64)
    private String refreshToken;

    @Column(name = "api_token", length = 64)
    private String apiToken;

    @Column(name = "token_activation", length = 64)
    private String tokenActivation;

    @Column(name = "token_restore", length = 64)
    private String tokenRestore;

    /** Null when no activation token is currently issued (mirrors {@link #tokenActivation}). */
    @Column(name = "token_activation_expires_at")
    private Instant tokenActivationExpiresAt;

    /** Null when no restore token is currently issued (mirrors {@link #tokenRestore}). */
    @Column(name = "token_restore_expires_at")
    private Instant tokenRestoreExpiresAt;

    @ManyToMany(fetch = FetchType.EAGER)
    @JoinTable(
            name = "role_users",
            joinColumns = @JoinColumn(name = "user_id"),
            inverseJoinColumns = @JoinColumn(name = "role_id"))
    @Setter(AccessLevel.NONE)
    private Set<Role> roles = new HashSet<>();

    /**
     * Groups this user belongs to. Bidirectional with
     * {@code Group.users} (which is the owning side). The back
     * reference is populated automatically by JPA on load/save —
     * to add the user to a group, call
     * {@code group.addUser(user)}, NOT this setter.
     */
    @ManyToMany(mappedBy = "users", fetch = FetchType.LAZY)
    @Setter(AccessLevel.NONE)
    private Set<Group> groups = new HashSet<>();

    public User(String email, String password) {
        this.email = email;
        this.password = password;
    }

    /**
     * Add a role to this user. We deliberately do not touch
     * {@link Role#getUsers()} from here — JPA populates the back-reference
     * automatically when the owning side ({@code User.roles}) is loaded.
     * Manually syncing both sides is a common source of
     * ConcurrentModificationException and infinite-loop bugs.
     */
    public void addRole(Role role) {
        this.roles.add(role);
    }

    public void removeRole(Role role) {
        this.roles.remove(role);
    }

    /* ==================== UserDetails contract ==================== */

    @Override
    public Collection<? extends GrantedAuthority> getAuthorities() {
        return roles.stream()
                .map(Role::getAuthority)
                .map(SimpleGrantedAuthorityAdapter::new)
                .collect(Collectors.toSet());
    }

    @Override
    public String getPassword() {
        return password;
    }

    /**
     * The {@link UserDetails} contract: Spring Security uses this
     * purely as the principal name on the {@code Authentication}.
     * Since the login identifier is now {@link #email}, this
     * returns the email address. Internal callers should prefer
     * {@link #getEmail()} for clarity.
     */
    @Override
    public String getUsername() {
        return email;
    }

    @Override
    public boolean isAccountNonExpired() {
        return accountNonExpired;
    }

    @Override
    public boolean isAccountNonLocked() {
        return accountNonLocked;
    }

    @Override
    public boolean isCredentialsNonExpired() {
        return credentialsNonExpired;
    }

    @Override
    public boolean isEnabled() {
        return enabled && active;
    }

    /**
     * Derived status for API/UI display — not a stored column.
     * {@code enabled}/{@code active} already encode three
     * distinguishable states unambiguously (see
     * {@code UserAdminService#createAccount}/{@code #activateAccount}/
     * {@code #deactivateAccount}), so this is computed rather than
     * persisted separately to avoid a second source of truth.
     */
    public UserStatus getStatus() {
        if (!active) {
            return UserStatus.INACTIVE;
        }
        return enabled ? UserStatus.ACTIVE : UserStatus.PENDING_ACTIVATION;
    }

    /**
     * @see #getStatus()
     */
    public enum UserStatus {
        /** Created by an admin, activation email sent, password not yet set. */
        PENDING_ACTIVATION,
        /** Activated and able to log in. */
        ACTIVE,
        /** Deactivated by an admin (was ACTIVE or PENDING_ACTIVATION). */
        INACTIVE
    }

    /* ====================== equality ====================== */

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof User other)) return false;
        return id != null && id.equals(other.id);
    }

    @Override
    public int hashCode() {
        return Objects.hashCode(id);
    }

    /**
     * Spring Security's {@code SimpleGrantedAuthority} lives in
     * spring-security-core but is normally in spring-security-config; we
     * wrap the role's string into a {@link SimpleGrantedAuthorityAdapter}
     * to avoid pulling in extra config. Spring Security's
     * {@code Authentication.getAuthorities()} accepts any
     * {@link GrantedAuthority}, so this works.
     */
    private record SimpleGrantedAuthorityAdapter(String authority) implements GrantedAuthority {
        @Override
        public String getAuthority() {
            return authority;
        }
    }
}
