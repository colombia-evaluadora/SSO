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

import java.util.HashSet;
import java.util.Objects;
import java.util.Set;

/**
 * Group entity. Mirrors the legacy {@code GROUPS} table from
 * {@code sso-service}. In the modernized stack, a {@code Group}
 * is a named collection of users — used for coarse-grained access
 * scoping (e.g. "operators of company X"). Per-user permissions
 * still go through {@link Role}.
 *
 * <p>Modernized version of the legacy
 * {@code com.co.lowcode.sso.model.Group}:
 * <ul>
 *   <li>Uses {@code jakarta.persistence.*} (not {@code javax.*}).</li>
 *   <li>Bidirectional {@code @ManyToMany} with {@link User} via
 *       the explicit {@code user_group} join table.</li>
 *   <li>The {@code @ManyToMany} on {@link #users} is the owning
 *       side — mutations go through {@link #addUser(User)} or
 *       {@link #removeUser(User)}, never through the back-reference.</li>
 * </ul>
 *
 * <p>Schema (mirrors the legacy DB):
 * <ul>
 *   <li>table: {@code groups}</li>
 *   <li>id column: {@code id_group}</li>
 *   <li>join table: {@code user_group} (FKs {@code user_id}, {@code group_id})</li>
 * </ul>
 *
 * <p>Note: {@code groups} is a reserved word in H2 (used in GROUP BY).
 * It is NOT reserved in Postgres. The test JDBC URL adds
 * {@code NON_KEYWORDS=GROUPS} to neutralize the H2 conflict.
 */
@Entity
@Table(name = "groups")
@Getter
@Setter
@NoArgsConstructor
public class Group {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "id_group")
    private Long id;

    @Column(name = "name", nullable = false, unique = true, length = 120)
    private String name;

    @Column(name = "description", length = 255)
    private String description;

    /**
     * Members of this group. Bidirectional with {@code User.groups}.
     * The owning side is here — we manage the join via
     * {@link #addUser(User)} / {@link #removeUser(User)} and the
     * back-reference on User is populated automatically by JPA
     * on load/save. Manually syncing both sides is a common
     * source of {@code ConcurrentModificationException} and
     * infinite-loop bugs.
     */
    @ManyToMany(fetch = FetchType.LAZY)
    @JoinTable(
            name = "user_group",
            joinColumns = @JoinColumn(name = "group_id"),
            inverseJoinColumns = @JoinColumn(name = "user_id"))
    @Setter(AccessLevel.NONE)
    private Set<User> users = new HashSet<>();

    public Group(String name) {
        this.name = name;
    }

    public Group(String name, String description) {
        this.name = name;
        this.description = description;
    }

    public void addUser(User user) {
        this.users.add(user);
    }

    public void removeUser(User user) {
        this.users.remove(user);
    }

    /**
     * Roles this group grants. A user in this group gains these roles
     * (in addition to their direct role_users roles) at token-issue
     * time — see auth-center's EffectiveRolesResolver.
     */
    @ManyToMany(fetch = FetchType.LAZY)
    @JoinTable(
            name = "group_role",
            joinColumns = @JoinColumn(name = "group_id"),
            inverseJoinColumns = @JoinColumn(name = "role_id"))
    @Setter(AccessLevel.NONE)
    private Set<Role> roles = new HashSet<>();

    public void addRole(Role role) {
        this.roles.add(role);
    }

    public void removeRole(Role role) {
        this.roles.remove(role);
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Group other)) return false;
        return id != null && id.equals(other.id);
    }

    @Override
    public int hashCode() {
        return Objects.hashCode(id);
    }
}
