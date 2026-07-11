package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.entity.User.UserStatus;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.common.repository.UserRepository;
import com.co.eurekatic.ssoadmin.client.SessionInvalidationClient;
import com.co.eurekatic.ssoadmin.config.EmailProperties;
import com.co.eurekatic.ssoadmin.dto.CreateAccountRequest;
import com.co.eurekatic.ssoadmin.dto.UpdateAccountRequest;
import com.co.eurekatic.ssoadmin.dto.UserResponse;
import com.co.eurekatic.ssoadmin.event.NotificationEventPublisher;
import com.co.eurekatic.ssoadmin.exception.EmailInvalidException;
import com.co.eurekatic.ssoadmin.exception.InvalidUserStateException;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import com.co.eurekatic.ssoadmin.exception.UserDuplicateException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.cache.Cache;
import org.springframework.cache.CacheManager;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

/**
 * User administration service. Mirrors the user-management
 * surface of the legacy {@code com.co.lowcode.sso.service.UserService}
 * — modernized to use JPA repos, the {@code common} module's
 * {@link User} / {@link Role} entities, and {@link EmailService}
 * for activation / restore flows.
 *
 * <p>Side effects:
 * <ul>
 *   <li>{@link #createAccount} — creates a User in the DB
 *       (status: {@code active=true}, {@code enabled=false},
 *       {@code password=null} until activation), issues an
 *       activation token, publishes an activation email event.
 *       Since the V12 migration {@code username} is gone — the
 *       email is the unique login identifier and serves as the
 *       row's primary natural key.</li>
 *   <li>{@link #activateAccount} — clears the activation token,
 *       sets {@code enabled=true} and {@code active=true},
 *       BCrypt-encodes the new password the user typed on the
 *       activation landing page. This is the FIRST place a
 *       password ever enters the system for that account.</li>
 *   <li>{@link #forgotPassword} — issues a restore token and
 *       publishes a restore-password email event. Always returns
 *       silently even if the email is unknown, to avoid leaking
 *       which addresses are registered. The user types a new
 *       password at {@code POST /restorePassword}.</li>
 *   <li>{@link #resendActivation} — only valid while
 *       {@link User#getStatus()} is PENDING_ACTIVATION; reissues
 *       the activation token and republishes the email (V13
 *       tokens expire, so this is how an admin recovers a user
 *       who missed the window).</li>
 *   <li>{@link #deactivateAccount} / {@link #reactivateAccount} —
 *       explicit ACTIVE ⇄ INACTIVE transitions, guarded by
 *       {@link User#getStatus()}. Deactivating flips
 *       {@code active=false}, which {@link User#isEnabled()}
 *       already treats as "can't log in" — see the class javadoc
 *       on {@code RefreshTokenStore} for the separate concern of
 *       revoking already-issued sessions.</li>
 * </ul>
 */
@Service
public class UserAdminService {

    private static final Logger log = LoggerFactory.getLogger(UserAdminService.class);
    // RFC-5322 is huge; this is a practical subset that catches
    // the common typos. The full check happens in the DTO with
    // @Email — this is the second line of defense.
    private static final Pattern EMAIL_REGEX =
            Pattern.compile("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$");

    private final UserRepository userRepository;
    private final RoleRepository roleRepository;
    private final PasswordEncoder passwordEncoder;
    private final TokenService tokenService;
    private final EmailService emailService;
    private final EmailProperties emailProps;
    private final NotificationEventPublisher events;
    private final SessionInvalidationClient sessionInvalidationClient;
    private final CacheManager cacheManager;

    public UserAdminService(UserRepository userRepository,
                            RoleRepository roleRepository,
                            PasswordEncoder passwordEncoder,
                            TokenService tokenService,
                            EmailService emailService,
                            EmailProperties emailProps,
                            NotificationEventPublisher events,
                            SessionInvalidationClient sessionInvalidationClient,
                            CacheManager cacheManager) {
        this.userRepository = userRepository;
        this.roleRepository = roleRepository;
        this.passwordEncoder = passwordEncoder;
        this.tokenService = tokenService;
        this.emailService = emailService;
        this.emailProps = emailProps;
        this.events = events;
        this.sessionInvalidationClient = sessionInvalidationClient;
        this.cacheManager = cacheManager;
    }

    /**
     * Creates a new user. The user is created in
     * {@code active=true} but {@code enabled=false} state with
     * no password yet — they have to click the activation link
     * in the email and POST {@code /activateAccount} with their
     * chosen password before they can log in.
     *
     * <p>The admin no longer types a username OR a password.
     * Email is the unique login identifier (the {@code users.username}
     * column was dropped in the V12 migration) and the first
     * password the system sees for the account is the one
     * the user enters on the activation landing page. This
     * mirrors the modern "password-set-by-owner" pattern and
     * removes two leak vectors: an admin with the
     * create-account role previously knew the initial password
     * of every account (and that password was overwritten on
     * activation anyway), and they had to type a "username" that
     * doubled as a publicly visible login id.
     */
    @Transactional
    public UserResponse createAccount(CreateAccountRequest req) {
        if (req.email() == null || !EMAIL_REGEX.matcher(req.email()).matches()) {
            throw new EmailInvalidException(req.email());
        }
        if (userRepository.existsByEmail(req.email())) {
            throw new UserDuplicateException(req.email());
        }

        User user = new User();
        user.setEmail(req.email());
        user.setFullName(req.fullName());
        // No passwordEncoder here — the password column is left
        // null until /activateAccount BCrypts and stamps it.
        user.setActive(true);
        user.setEnabled(false);
        user.setLdap(false);

        if (req.roleNames() != null && !req.roleNames().isEmpty()) {
            Set<Role> roles = resolveRoles(req.roleNames());
            for (Role r : roles) {
                user.addRole(r);
            }
        }

        tokenService.issueActivationToken(user);
        User saved = userRepository.save(user);
        publishActivationEmail(saved);
        // Roles were just attached — drop the (currently empty)
        // cache entry so the activation flow sees them on first
        // login. Until activation the user is enabled=false and
        // cannot log in, so this is technically a no-op, but it
        // keeps the invalidation rule simple: any role change
        // invalidates, period.
        sessionInvalidationClient.invalidate(saved.getEmail());
        evictUserByEmailCache(saved.getEmail());

        log.info("Created user '{}' (active=true, enabled=false, pending activation)",
                saved.getEmail());
        return UserResponse.fromEntity(saved);
    }

    /**
     * Reissues an activation token for a user still in
     * {@link UserStatus#PENDING_ACTIVATION} and republishes the
     * activation email — for when the original token expired
     * (or the email was lost) before the user activated.
     * Overwrites any still-live token, same idempotent-reissue
     * pattern as {@link #forgotPassword}.
     */
    @Transactional
    public void resendActivation(Long userId) {
        User user = userRepository.findById(userId)
                .orElseThrow(() -> new NotFoundException("User", userId));
        if (user.getStatus() != UserStatus.PENDING_ACTIVATION) {
            throw new InvalidUserStateException("Resend activation", user.getStatus(), UserStatus.PENDING_ACTIVATION);
        }
        tokenService.issueActivationToken(user);
        User saved = userRepository.save(user);
        publishActivationEmail(saved);
        log.info("Resent activation email for user '{}'", saved.getEmail());
    }

    private void publishActivationEmail(User user) {
        String token = user.getTokenActivation();
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("displayName", user.getFullName() == null ? user.getEmail() : user.getFullName());
        payload.put("email", user.getEmail());
        payload.put("activationLink", emailProps.activationUrl() + "?token=" + token);
        payload.put("ttlMinutes", TokenService.ACTIVATION_TTL_MINUTES);
        events.publish("email", String.valueOf(user.getId()), user.getEmail(),
                "account-activation", payload, null);
    }

    /**
     * Deactivates an ACTIVE user: blocks future login (via
     * {@link User#isEnabled()}) and publishes the existing
     * {@code account-deactivated} notification. Does NOT revoke
     * already-issued JWT/refresh tokens yet — that lands
     * alongside {@code RefreshTokenStore.revokeAllForUser} in a
     * follow-up change.
     */
    @Transactional
    public void deactivateAccount(Long userId, String reason) {
        User user = userRepository.findById(userId)
                .orElseThrow(() -> new NotFoundException("User", userId));
        if (user.getStatus() != UserStatus.ACTIVE) {
            throw new InvalidUserStateException("Deactivate", user.getStatus(), UserStatus.ACTIVE);
        }
        user.setActive(false);
        User saved = userRepository.save(user);
        publishAccountDeactivated(saved, reason == null || reason.isBlank() ? "Deactivated by admin" : reason);
        log.info("Deactivated user '{}'", saved.getEmail());
    }

    /**
     * Reactivates a previously deactivated user. Counterpart to
     * {@link #deactivateAccount}.
     */
    @Transactional
    public void reactivateAccount(Long userId) {
        User user = userRepository.findById(userId)
                .orElseThrow(() -> new NotFoundException("User", userId));
        if (user.getStatus() != UserStatus.INACTIVE) {
            throw new InvalidUserStateException("Reactivate", user.getStatus(), UserStatus.INACTIVE);
        }
        user.setActive(true);
        User saved = userRepository.save(user);
        publishAccountReactivated(saved);
        log.info("Reactivated user '{}'", saved.getEmail());
    }

    /**
     * Updates mutable fields on an existing user. Null fields are
     * left unchanged. If {@code roleNames} is non-null, it
     * REPLACES the user's current role set.
     *
     * <p>Lookup is by {@code id} (the user's numeric PK), NOT by
     * email — email is mutable and not a stable identity key.
     */
    @Transactional
    public UserResponse updateAccount(UpdateAccountRequest req) {
        User user = userRepository.findById(req.id())
                .orElseThrow(() -> new NotFoundException("User", req.id()));

        if (req.fullName() != null) user.setFullName(req.fullName());
        if (req.email() != null) {
            if (!EMAIL_REGEX.matcher(req.email()).matches()) {
                throw new EmailInvalidException(req.email());
            }
            user.setEmail(req.email());
        }
        if (req.active() != null) user.setActive(req.active());
        if (req.ldap() != null) user.setLdap(req.ldap());

        if (req.roleNames() != null) {
            // Replace strategy: remove roles that aren't in the
            // new set, add the ones that are. The
            // @Setter(AccessLevel.NONE) on User.roles means we
            // mutate the existing Set rather than replacing it.
            Set<Role> current = user.getRoles();
            Set<String> wanted = req.roleNames().stream()
                    .collect(Collectors.toCollection(LinkedHashSet::new));
            Set<String> removed = current.stream()
                    .map(Role::getName)
                    .filter(n -> !wanted.contains(n))
                    .collect(Collectors.toCollection(LinkedHashSet::new));
            current.removeIf(r -> !wanted.contains(r.getName()));
            for (String name : wanted) {
                if (current.stream().noneMatch(r -> r.getName().equals(name))) {
                    Role role = roleRepository.findByName(name)
                            .orElseThrow(() -> new NotFoundException("Role", name));
                    user.addRole(role);
                }
            }
            // Publish role-revoked for every role removed by the
            // replace strategy (single bulk update).
            for (String roleName : removed) {
                publishRoleRevoked(user, roleName);
            }
        }

        User saved = userRepository.save(user);
        if (req.roleNames() != null) {
            // Roles just changed — drop the cache so the next
            // /login (or /auth/refresh) re-reads the new set
            // instead of handing out the old one for the rest
            // of the TTL window.
            sessionInvalidationClient.invalidate(saved.getEmail());
            evictUserByEmailCache(saved.getEmail());
        }

        if (req.active() != null && !req.active()) {
            publishAccountDeactivated(saved, "Disabled via admin update");
        }

        return UserResponse.fromEntity(saved);
    }

    /**
     * Activates a user via the token issued in
     * {@link #createAccount}. Sets {@code enabled=true},
     * {@code active=true}, BCrypt-encodes the new password, and
     * clears the token column.
     */
    @Transactional
    public void activateAccount(String token, String password) {
        if (password == null || password.isBlank() || password.length() < 6) {
            throw new IllegalArgumentException("Password must be at least 6 characters");
        }
        User user = tokenService.consumeActivationToken(token);
        user.setPassword(passwordEncoder.encode(password));
        user.setEnabled(true);
        user.setActive(true);
        User saved = userRepository.save(user);
        log.info("Activated user '{}'", saved.getEmail());

        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("displayName", saved.getFullName() == null ? saved.getEmail() : saved.getFullName());
        payload.put("email", saved.getEmail());
        events.publish("email", String.valueOf(saved.getId()), saved.getEmail(),
                "account-activated", payload, null);
    }

    /**
     * Restores a password via the token sent in
     * {@link #forgotPassword}. Same as {@link #activateAccount}
     * but for the restore flow.
     */
    @Transactional
    public void restorePassword(String token, String password) {
        if (password == null || password.isBlank() || password.length() < 6) {
            throw new IllegalArgumentException("Password must be at least 6 characters");
        }
        User user = tokenService.consumeRestoreToken(token);
        user.setPassword(passwordEncoder.encode(password));
        User saved = userRepository.save(user);
        log.info("Restored password for user '{}'", saved.getEmail());

        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("displayName", saved.getFullName() == null ? saved.getEmail() : saved.getFullName());
        payload.put("email", saved.getEmail());
        events.publish("email", String.valueOf(saved.getId()), saved.getEmail(),
                "password-changed", payload, null);
    }

    /**
     * Issues a restore-password email. Always returns
     * successfully (even if the email is unknown) so the API
     * doesn't leak which addresses are registered.
     */
    @Transactional
    public void forgotPassword(String email) {
        userRepository.findAll().stream()
                .filter(u -> email.equals(u.getEmail()))
                .findFirst()
                .ifPresent(u -> {
                    String token = tokenService.issueRestoreToken(u);
                    userRepository.save(u);

                    Map<String, Object> payload = new LinkedHashMap<>();
                    payload.put("displayName", u.getFullName() == null ? u.getEmail() : u.getFullName());
                    payload.put("email", u.getEmail());
                    payload.put("resetLink", emailProps.restoreUrl() + "?token=" + token);
                    payload.put("ttlMinutes", 30);
                    events.publish("email", String.valueOf(u.getId()), u.getEmail(),
                            "password-reset", payload, null);
                });
    }

    /**
     * Lists all users (id, fullName, email, ldap, active).
     * The legacy returned a flat Map list; we return a typed
     * {@code List<UserResponse>}.
     */
    @Transactional(readOnly = true)
    public List<UserResponse> getUsers() {
        return userRepository.findAll().stream()
                .map(UserResponse::fromEntity)
                .toList();
    }

    /**
     * Returns the role names for the given email. The legacy
     * {@code getRolesByUsername} was renamed so the URL
     * reflects the actual lookup key (email IS the unique
     * login identifier since the V12 migration).
     */
    @Transactional(readOnly = true)
    public List<String> getRolesByEmail(String email) {
        return userRepository.findByEmail(email)
                .orElseThrow(() -> new NotFoundException("User", email))
                .getRoles().stream()
                .map(Role::getName)
                .collect(Collectors.toList());
    }

    /**
     * Binds a role to a user. Idempotent — re-binding the same
     * pair is a no-op.
     */
    @Transactional
    public void bindUserRole(Long userId, Long roleId) {
        User user = userRepository.findById(userId)
                .orElseThrow(() -> new NotFoundException("User", userId));
        Role role = roleRepository.findById(roleId)
                .orElseThrow(() -> new NotFoundException("Role", roleId));
        boolean alreadyBound = user.getRoles().stream().anyMatch(r -> r.getId().equals(roleId));
        user.addRole(role);
        User saved = userRepository.save(user);
        if (!alreadyBound) {
            publishRoleAssigned(saved, role.getName());
            // New role granted — the cached role set no longer
            // matches the DB. Drop it so the next login mints a
            // JWT that includes the new role.
            sessionInvalidationClient.invalidate(saved.getEmail());
            evictUserByEmailCache(saved.getEmail());
        }
    }

    /**
     * Unbinds a role from a user. Idempotent — unbinding a
     * non-existent pair is a no-op.
     */
    @Transactional
    public void unbindUserRole(Long userId, Long roleId) {
        User user = userRepository.findById(userId)
                .orElseThrow(() -> new NotFoundException("User", userId));
        String removedRoleName = user.getRoles().stream()
                .filter(r -> r.getId().equals(roleId))
                .findFirst()
                .map(Role::getName)
                .orElse(null);
        user.getRoles().stream()
                .filter(r -> r.getId().equals(roleId))
                .findFirst()
                .ifPresent(user::removeRole);
        User saved = userRepository.save(user);
        if (removedRoleName != null) {
            publishRoleRevoked(saved, removedRoleName);
            // Role revoked — cached role set now over-claims the
            // user's authorities. Drop it.
            sessionInvalidationClient.invalidate(saved.getEmail());
            evictUserByEmailCache(saved.getEmail());
        }
    }

    /**
     * Returns the user's roles as a list of role names. The
     * legacy endpoint {@code GET /user/roles?userId} returned a
     * {@code List<Map>} — we return a typed
     * {@code List<String>}.
     */
    @Transactional(readOnly = true)
    public List<String> getRolesForUser(Long userId) {
        User user = userRepository.findById(userId)
                .orElseThrow(() -> new NotFoundException("User", userId));
        return user.getRoles().stream().map(Role::getName).toList();
    }

    private Set<Role> resolveRoles(List<String> names) {
        Set<Role> result = new LinkedHashSet<>();
        for (String name : names) {
            Role role = roleRepository.findByName(name)
                    .orElseThrow(() -> new NotFoundException("Role", name));
            result.add(role);
        }
        return result;
    }

    // ---- cache helpers ----------------------------------------

    /**
     * Evicts the {@code "user-by-email"} Redis cache for the
     * given email so the next {@code QueryCatalogService} call
     * re-reads the user's current role set instead of using the
     * stale cached projection.
     */
    private void evictUserByEmailCache(String email) {
        Cache cache = cacheManager.getCache("user-by-email");
        if (cache != null) {
            cache.evict(email);
        }
    }

    // ---- notification helpers -------------------------------------

    private void publishRoleAssigned(User user, String roleName) {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("displayName", user.getFullName() == null ? user.getEmail() : user.getFullName());
        payload.put("email", user.getEmail());
        payload.put("roleName", roleName);
        events.publish("email", String.valueOf(user.getId()), user.getEmail(),
                "role-assigned", payload, null);
    }

    private void publishRoleRevoked(User user, String roleName) {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("displayName", user.getFullName() == null ? user.getEmail() : user.getFullName());
        payload.put("email", user.getEmail());
        payload.put("roleName", roleName);
        events.publish("email", String.valueOf(user.getId()), user.getEmail(),
                "role-revoked", payload, null);
    }

    private void publishAccountDeactivated(User user, String reason) {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("displayName", user.getFullName() == null ? user.getEmail() : user.getFullName());
        payload.put("email", user.getEmail());
        payload.put("reason", reason);
        events.publish("email", String.valueOf(user.getId()), user.getEmail(),
                "account-deactivated", payload, null);
    }

    private void publishAccountReactivated(User user) {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("displayName", user.getFullName() == null ? user.getEmail() : user.getFullName());
        payload.put("email", user.getEmail());
        events.publish("email", String.valueOf(user.getId()), user.getEmail(),
                "account-reactivated", payload, null);
    }
}
