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
 * Route — a navigable menu item in the legacy lowcode
 * platform. The route tree is a self-referencing structure
 * (each route has zero or one parent) and each route can be
 * granted to one or more roles. Mirrors the legacy
 * {@code ROUTE} table.
 *
 * <p>Notes:
 * <ul>
 *   <li>{@code IDPARENT} is a self-FK. The legacy uses
 *       {@code 0} as the sentinel for "root"; the modern
 *       port normalizes incoming {@code "0"} to {@code null}
 *       in the service layer so JPA can treat roots uniformly.</li>
 *   <li>The legacy {@code COMPONENT_ID_COMPONENT} column
 *       pointed at a RethinkDB-only table that doesn't exist
 *       in the relational schema; it is omitted from the
 *       modernized entity.</li>
 * </ul>
 */
@Entity
@Table(name = "ROUTE")
@Getter
@Setter
@NoArgsConstructor
public class Route {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "ID_ROUTE")
    private Long id;

    @Column(name = "NAME", nullable = false, length = 200)
    private String name;

    @Column(name = "ICON", length = 200)
    private String icon;

    @Column(name = "PATH", nullable = false, length = 500)
    private String path;

    @Column(name = "MENUORDER", nullable = false)
    private Integer menuOrder = 0;

    @Column(name = "TYPE", length = 50)
    private String type;

    /**
     * Self-FK to the parent route. {@code null} = root.
     * The legacy stored {@code 0} for roots; the service
     * layer normalizes incoming {@code "0"} to {@code null}
     * on write.
     */
    @Column(name = "IDPARENT")
    private Long idParent;

    /**
     * Roles that are allowed to see/use this route. Owning
     * side of {@code ROLE_ROUTE} — call {@link #addRole(Role)}
     * to attach.
     */
    @ManyToMany(fetch = FetchType.LAZY)
    @JoinTable(
            name = "ROLE_ROUTE",
            joinColumns = @JoinColumn(name = "ROUTE_ID"),
            inverseJoinColumns = @JoinColumn(name = "ROLE_ID"))
    @Setter(AccessLevel.NONE)
    private Set<Role> roles = new HashSet<>();

    public void addRole(Role r) {
        this.roles.add(r);
    }

    public void removeRole(Role r) {
        this.roles.remove(r);
    }

    /* ====================== equality ====================== */

    @Override
    public boolean equals(Object o) {
        if (this == o) return true;
        if (!(o instanceof Route other)) return false;
        return id != null && id.equals(other.id);
    }

    @Override
    public int hashCode() {
        return Objects.hashCode(id);
    }
}
