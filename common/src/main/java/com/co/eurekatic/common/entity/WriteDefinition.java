package com.co.eurekatic.common.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.FetchType;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.JoinTable;
import jakarta.persistence.ManyToMany;
import jakarta.persistence.ManyToOne;
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
 * WriteDefinition — a parameterized INSERT / UPDATE description
 * indexed by {@code uuid}, addressable from {@code query-service}
 * via the catalog endpoint {@code GET /getWrite?uuid=...}.
 *
 * <p>Design contract (see spec §6): the caller NEVER sends table
 * or column names. The client sends the {@code uuid} + a map of
 * values; this entity carries the only authoritative identifiers
 * (table, columns, key columns). {@code query-service} consumes
 * this definition, validates that the caller's value keys are a
 * subset of {@link #columns}, and builds the SQL with
 * {@code setParameter}. SQL injection by construction is
 * impossible because identifiers never reach the request body.
 *
 * <p>Table layout keeps the legacy {@code UPPER_CASE} style for
 * column names. {@code COLUMNS} and {@code KEY_COLUMNS} are
 * stored as JSON-encoded arrays ({@code ["COL_A","COL_B"]}) so
 * we don't need a separate join table for what is fundamentally
 * an ordered, non-relational allowlist.
 *
 * <p>Relations:
 * <ul>
 *   <li>{@link #microservice} — many-to-one. The intended
 *       {@code query-service-<instanceName>} target (must be
 *       {@code kind=QUERY} if non-null). Nullable; null means
 *       "global" (any instance with the right datasource may
 *       serve it). Mirrors the binding on {@link Query} so the
 *       admin-ui can offer a per-instance table picker.</li>
 *   <li>{@link #roles} — many-to-many. Owning side of
 *       {@code ROLE_WRITE}. Call {@link #addRole(Role)} to grant
 *       a role write access. The catalog endpoint enforces this
 *       join.</li>
 * </ul>
 */
@Entity
@Table(name = "WRITE_DEFINITION")
@Getter
@Setter
@NoArgsConstructor
public class WriteDefinition {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "ID_WRITE_DEFINITION")
    private Long id;

    @Column(name = "UUID", nullable = false, unique = true, length = 64)
    private String uuid;

    /**
     * INSERT or UPDATE. The catalog endpoint returns this
     * verbatim and {@code query-service}'s {@code WriteService}
     * dispatches on it. Stored as VARCHAR to avoid coupling the
     * DB schema to the Java enum's ordinal position.
     */
    @Enumerated(EnumType.STRING)
    @Column(name = "WRITE_TYPE", nullable = false, length = 16)
    private WriteType writeType;

    /**
     * Qualified table name (e.g. {@code "public.users"}).
     * Validated against an identifier regex by {@code query-service}
     * before being interpolated into SQL — defense in depth in
     * case the catalog ever leaks a bad row.
     */
    @Column(name = "TABLE_NAME", nullable = false, length = 200)
    private String tableName;

    /**
     * Allowlist of writable columns. Stored as a JSON array of
     * strings ({@code ["COL_A","COL_B"]}). The caller MUST only
     * provide values for columns in this set; anything else is
     * rejected with 400.
     */
    @Column(name = "COLUMNS", nullable = false, columnDefinition = "text")
    private String columns;

    /**
     * For UPDATE: the columns used in the WHERE clause. Empty
     * for INSERT. JSON array of column names. All entries must
     * be present in the caller's value map or the request is
     * rejected with 400.
     */
    @Column(name = "KEY_COLUMNS", columnDefinition = "text")
    private String keyColumns;

    /**
     * DB-managed timestamp.
     */
    @Column(name = "CREATEDDATE", insertable = false, updatable = false)
    private LocalDateTime createdDate;

    /**
     * Which {@link Microservice} instance (kind=QUERY) is the
     * intended target for this write. Nullable — a {@code NULL}
     * value means the write is "global" and any
     * {@code query-service-<instanceName>} with the right
     * datasource may serve it. The admin-ui Writes Catalog
     * uses this to filter the table-picker dropdown per
     * backing instance (mirrors the pattern established on
     * {@link Query#getMicroservice()}).
     */
    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "MICROSERVICE_ID")
    private Microservice microservice;

    @ManyToMany(fetch = FetchType.LAZY)
    @JoinTable(
            name = "ROLE_WRITE",
            joinColumns = @JoinColumn(name = "WRITE_DEFINITION_ID"),
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
        if (!(o instanceof WriteDefinition other)) return false;
        return id != null && id.equals(other.id);
    }

    @Override
    public int hashCode() {
        return Objects.hashCode(id);
    }
}
