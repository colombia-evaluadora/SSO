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
 * Query — a parameterized SQL definition indexed by {@code uuid},
 * addressable from {@code query-service} via the catalog
 * endpoint {@code GET /getQuery?uuid=...}.
 *
 * <p>Mirrors the legacy {@code REPORT} table from
 * {@code sso-service}. The {@code uuid} is the stable, public
 * handle — clients send the uuid (not SQL), {@code query-service}
 * asks {@code sso-admin} to resolve the SQL, and {@code sso-admin}
 * enforces that the caller has a role bound to this query before
 * returning the definition. This keeps authorization for SQL
 * execution in one place (the catalog) and removes any need for
 * the calling service to know about table or column names.
 *
 * <p>Table layout keeps the legacy {@code UPPER_CASE} style for
 * column names ({@code ID_QUERY}, {@code QUERY}, etc.) so cross-
 * table joins with the legacy SQL continue to work while the
 * schema is shared. Modern code reads/writes through the Java
 * field names.
 *
 * <p>Relations:
 * <ul>
 *   <li>{@link #roles} — many-to-many. Owning side of the
 *       {@code ROLE_QUERY} join table. Call
 *       {@link #addRole(Role)} to grant a role access to this
 *       query. The {@code query-service} caller must have at
 *       least one role in this set; the join is enforced by the
 *       catalog endpoint, not by Spring Security.</li>
 * </ul>
 *
 * <p>Notes:
 * <ul>
 *   <li>{@code publicEnd} controls whether a non-authenticated
 *       client (via {@code /public/service} on query-service)
 *       may invoke the query. The check still goes through the
 *       catalog endpoint — this flag just gates whether the
 *       public caller is allowed in addition to role-bound
 *       users.</li>
 *   <li>{@code captcha} indicates that the query requires a
 *       captcha-verified caller (reCAPTCHA, validated by
 *       {@code query-service}).</li>
 *   <li>{@code detail} / {@code action} / {@code style} are
 *       free-form JSON blobs (passed as String, deserialized by
 *       the consumer) carrying UI metadata for the low-code
 *       client.</li>
 * </ul>
 */
@Entity
@Table(name = "QUERY")
@Getter
@Setter
@NoArgsConstructor
public class Query {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "ID_QUERY")
    private Long id;

    @Column(name = "UUID", nullable = false, unique = true, length = 64)
    private String uuid;

    /**
     * Raw SQL (or stored-procedure call expression) that the
     * catalog returns. Parameter binding happens on the consumer
     * side via {@code setParameter} — values never go through
     * string concatenation.
     */
    @Column(name = "QUERY", nullable = false, columnDefinition = "text")
    private String query;

    /**
     * Free-form type — historically {@code "QUERY"} or
     * {@code "CHART"}. We store as VARCHAR to keep the legacy
     * values exact; the catalog passes it through verbatim.
     */
    @Column(name = "TYPE", length = 64)
    private String type;

    @Column(name = "PUBLIC_END", nullable = false)
    private boolean publicEnd = false;

    @Column(name = "CAPTCHA", nullable = false)
    private boolean captcha = false;

    /**
     * UI metadata for low-code renderers. JSON encoded; the
     * consumer deserializes on demand.
     */
    @Column(name = "DETAIL", columnDefinition = "text")
    private String detail;

    @Column(name = "ACTION", columnDefinition = "text")
    private String action;

    @Column(name = "STYLE", columnDefinition = "text")
    private String style;

    /**
     * DB-managed timestamp. Never written from Java — the
     * schema defaults it to {@code now()} on insert. JPA marks
     * it {@code insertable=false, updatable=false} so we don't
     * fight the DB default.
     */
    @Column(name = "CREATEDDATE", insertable = false, updatable = false)
    private LocalDateTime createdDate;

    /**
     * Which {@link Microservice} instance (kind=QUERY) owns
     * this query. Nullable — a {@code NULL} value means the
     * query is "global" and any instance with the right
     * datasource may serve it. The admin-ui Queries Catalog
     * uses this to group queries by backing instance and to
     * pick the right {@code query-service-<instanceName>}
     * gateway path when executing.
     */
    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "MICROSERVICE_ID")
    private Microservice microservice;

    /**
     * Roles authorized to invoke this query through the catalog
     * endpoint. Owning side of {@code ROLE_QUERY} — call
     * {@link #addRole(Role)} to attach.
     */
    @ManyToMany(fetch = FetchType.LAZY)
    @JoinTable(
            name = "ROLE_QUERY",
            joinColumns = @JoinColumn(name = "QUERY_ID"),
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
        if (!(o instanceof Query other)) return false;
        return id != null && id.equals(other.id);
    }

    @Override
    public int hashCode() {
        return Objects.hashCode(id);
    }
}
