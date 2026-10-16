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
import jakarta.persistence.OneToMany;
import jakarta.persistence.Table;
import lombok.AccessLevel;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.LocalDateTime;
import java.util.HashSet;
import java.util.Objects;
import java.util.Set;

/**
 * App — the top-level grouping that mirrors the legacy
 * {@code SSO_V2.APP} table from the previous platform.
 *
 * <p>An app aggregates:
 * <ul>
 *   <li>{@link #routes} — which navigable entries (the legacy "menu
 *       items") belong to this app. Bound via the
 *       {@code app_route} join table.</li>
 *   <li>{@link #microservices} — which downstream services this app
 *       exposes. Bound via {@code app_microservice}.</li>
 *   <li>{@link #users} — explicit app membership (the membership
 *       is per-user; permissions come via roles, but the link
 *       itself is user→app).</li>
 *   <li>{@link #roles} — which roles can see this app and (broadly)
 *       all its routes. Fine-grained access still goes via
 *       {@code role_route} on individual {@link Route}s.</li>
 * </ul>
 *
 * <p>Back-references on the joined entities are intentionally NOT
 * declared — JPA populates them automatically on load/save, and
 * keeping the owning side alone avoids bidirectional sync bugs
 * (see the Javadoc on {@link User#addRole(Role)} for the same
 * pattern).
 *
 * <p>The {@link #microservicePrimary} OneToMany list is the
 * inverse side of {@link Microservice#getApp()} — populated by
 * JPA on load, useful when navigating from an app to its
 * "primary" microservice (the FK column) without going through
 * the M:N join. {@link Route} has no equivalent FK/primary
 * pointer — {@code app_route} ({@link #routes}) is its sole
 * app-membership relationship.
 */
@Entity
@Table(name = "app")
@Getter
@Setter
@NoArgsConstructor
public class App {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "id_app")
    private Long id;

    @Column(name = "name", nullable = false, unique = true, length = 255)
    private String name;

    @Column(name = "description", length = 500)
    private String description;

    /**
     * Where clicking this app takes the user, post-login. A
     * relative path (e.g. {@code /admin/}) means "this same SPA";
     * an absolute URL means an external app entirely — see
     * {@code AppLauncherPage} in admin-ui.
     */
    @Column(name = "launch_url", length = 500)
    private String launchUrl;

    /**
     * DB-managed timestamp. JPA marks it
     * {@code insertable=false, updatable=false} so we don't
     * fight the {@code DEFAULT CURRENT_TIMESTAMP}.
     */
    @Column(name = "created_date", insertable = false, updatable = false)
    private LocalDateTime createdDate;

    /**
     * Roles that can see this app. Owning side of
     * {@code role_app} — call {@link #addRole(Role)} to attach.
     */
    @ManyToMany(fetch = FetchType.LAZY)
    @JoinTable(
            name = "role_app",
            joinColumns = @JoinColumn(name = "id_app"),
            inverseJoinColumns = @JoinColumn(name = "id_role"))
    @Setter(AccessLevel.NONE)
    private Set<Role> roles = new HashSet<>();

    /**
     * Users that belong to this app (explicit membership).
     * Owning side of {@code app_users} — call
     * {@link #addUser(User)} to attach.
     */
    @ManyToMany(fetch = FetchType.LAZY)
    @JoinTable(
            name = "app_users",
            joinColumns = @JoinColumn(name = "id_app"),
            inverseJoinColumns = @JoinColumn(name = "id_user"))
    @Setter(AccessLevel.NONE)
    private Set<User> users = new HashSet<>();

    /**
     * Routes that are part of this app (M:N membership).
     * Owning side of {@code app_route} — call
     * {@link #addRoute(Route)} to attach.
     */
    @ManyToMany(fetch = FetchType.LAZY)
    @JoinTable(
            name = "app_route",
            joinColumns = @JoinColumn(name = "id_app"),
            inverseJoinColumns = @JoinColumn(name = "id_route"))
    @Setter(AccessLevel.NONE)
    private Set<Route> routes = new HashSet<>();

    /**
     * Microservices that belong to this app. Owning side of
     * {@code app_microservice} — call
     * {@link #addMicroservice(Microservice)} to attach.
     */
    @ManyToMany(fetch = FetchType.LAZY)
    @JoinTable(
            name = "app_microservice",
            joinColumns = @JoinColumn(name = "id_app"),
            inverseJoinColumns = @JoinColumn(name = "id_microservice"))
    @Setter(AccessLevel.NONE)
    private Set<Microservice> microservices = new HashSet<>();

    /**
     * Inverse side of {@link Microservice#getApp()} —
     * microservices whose {@code id_app} FK points at this
     * app. Read-only via JPA; to attach a microservice as
     * the "primary" of this app, call
     * {@code microservice.setApp(this)}, not the setter here.
     *
     * <p>{@link Route} has no equivalent FK — {@code app_route}
     * ({@link #routes}) is the sole app-membership relationship
     * for routes; see {@link com.co.eurekatic.common.repository.RouteRepository}.
     */
    @OneToMany(mappedBy = "app", fetch = FetchType.LAZY)
    @Setter(AccessLevel.NONE)
    private Set<Microservice> microservicePrimary = new HashSet<>();

    /* ====================== helpers ====================== */

    public void addRole(Role r) { this.roles.add(r); }
    public void removeRole(Role r) { this.roles.remove(r); }

    public void addUser(User u) { this.users.add(u); }
    public void removeUser(User u) { this.users.remove(u); }

    public void addRoute(Route r) { this.routes.add(r); }
    public void removeRoute(Route r) { this.routes.remove(r); }

    public void addMicroservice(Microservice m) { this.microservices.add(m); }
    public void removeMicroservice(Microservice m) { this.microservices.remove(m); }

    /* ====================== equality ====================== */

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof App other)) return false;
        return id != null && id.equals(other.id);
    }

    @Override
    public int hashCode() {
        return Objects.hashCode(id);
    }
}