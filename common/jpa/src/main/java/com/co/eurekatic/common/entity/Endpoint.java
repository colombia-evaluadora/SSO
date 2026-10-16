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
 * Endpoint — a single HTTP method+path inside a microservice
 * (e.g. {@code GET /api/users}). Mirrors the legacy
 * {@code ENDPOINT} table from {@code sso-service}.
 *
 * <p>Uniqueness in the legacy is the combination of
 * {@code PATH + METHOD + DESCRIPTION} — we mirror that with
 * a DB-level unique constraint in the migration script.
 *
 * <p>Relations:
 * <ul>
 *   <li>{@link #microservices} — many-to-many. Owning side
 *       of the {@code ENDPOINT_MICROSERVICE} join table.
 *       Call {@code endpoint.addMicroservice(ms)} to attach.</li>
 *   <li>{@link #roles} — many-to-many. Which roles can invoke
 *       this endpoint. Owning side of {@code ROLE_ENDPOINT}.
 *       Call {@code endpoint.addRole(r)} to attach.</li>
 * </ul>
 */
@Entity
@Table(name = "ENDPOINT")
@Getter
@Setter
@NoArgsConstructor
public class Endpoint {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "ID_ENDPOINT")
    private Long id;

    @Column(name = "METHOD", nullable = false, length = 10)
    private String method;

    @Column(name = "PATH", nullable = false, length = 500)
    private String path;

    @Column(name = "DESCRIPTION", length = 500)
    private String description;

    @Column(name = "NUMBERPARAMS", nullable = false)
    private Integer numberParams = 0;

    /**
     * Microservices that expose this endpoint. Owning side of
     * the many-to-many — call {@link #addMicroservice(Microservice)}
     * to attach a new microservice.
     */
    @ManyToMany(fetch = FetchType.LAZY)
    @JoinTable(
            name = "ENDPOINT_MICROSERVICE",
            joinColumns = @JoinColumn(name = "ENDPOINT_ID"),
            inverseJoinColumns = @JoinColumn(name = "MICROSERVICE_ID"))
    @Setter(AccessLevel.NONE)
    private Set<Microservice> microservices = new HashSet<>();

    /**
     * Roles that are allowed to invoke this endpoint. Owning
     * side of the {@code ROLE_ENDPOINT} join table — call
     * {@link #addRole(Role)} to attach a new role.
     */
    @ManyToMany(fetch = FetchType.LAZY)
    @JoinTable(
            name = "ROLE_ENDPOINT",
            joinColumns = @JoinColumn(name = "ENDPOINT_ID"),
            inverseJoinColumns = @JoinColumn(name = "ROLE_ID"))
    @Setter(AccessLevel.NONE)
    private Set<Role> roles = new HashSet<>();

    public void addMicroservice(Microservice m) {
        this.microservices.add(m);
    }

    public void removeMicroservice(Microservice m) {
        this.microservices.remove(m);
    }

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
        if (!(o instanceof Endpoint other)) return false;
        return id != null && id.equals(other.id);
    }

    @Override
    public int hashCode() {
        return Objects.hashCode(id);
    }
}
