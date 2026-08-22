package com.co.eurekatic.common.entity;

import jakarta.persistence.CascadeType;
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
import jakarta.persistence.OneToMany;
import jakarta.persistence.Table;
import lombok.AccessLevel;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;

import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

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
     * V28 — how the JDBC layer should execute this query.
     * Default {@code "SELECT"} preserves pre-V28 behavior.
     * Stored as VARCHAR (not Java enum) so the database
     * remains the schema of record: an admin can update the
     * column directly without going through the enum ordinal
     * trap that bit the legacy code.
     */
    @Column(name = "EXECUTION_MODE", length = 20, nullable = false)
    private String executionMode = "SELECT";

    /**
     * V27 — path template that exposes this query as an HTTP
     * endpoint, composed with {@link Microservice#getRequestUri()}.
     * Example: when the owning microservice has
     * {@code REQUEST_URI = "/api/eval-col/**"} and this column
     * holds {@code "/establecimiento/{id}"}, the gateway exposes
     * the query at {@code POST /api/eval-col/establecimiento/{id}}.
     *
     * <p>Nullable: {@code NULL} keeps the legacy
     * {@code POST /<svc>/query {uuid}} flow as the only way to
     * invoke. Catalog rows authored before V27 stay exactly
     * as they were.
     */
    @Column(name = "PATH_TEMPLATE", length = 500)
    private String pathTemplate;

    /**
     * V33 — verbo HTTP que expone esta fila cuando tiene
     * {@code pathTemplate}: {@code GET}, {@code POST} o {@code PUT}.
     *
     * <p>El default {@code POST} es lo que hace que V33 no rompa
     * nada: antes toda ruta era un POST, así que cada fila
     * existente conserva su comportamiento sin migrar datos.
     *
     * <p>{@code DELETE} no se admite a propósito. No hay
     * impedimento técnico — un {@code CALL paquete.borrar(...)}
     * funcionaría igual que cualquier otro procedimiento — pero
     * mantener el verbo fuera evita que una URL sugiera un borrado
     * directo sobre tablas.
     */
    @Column(name = "HTTP_METHOD", length = 10, nullable = false)
    private String httpMethod = "POST";

    /**
     * V31 — comma-separated {@code :placeholder} names that are
     * OUT params of a PROCEDURE-mode row. When set,
     * {@code query-service} switches to {@code CallableStatement}
     * and reads the OUT values into a separate {@code outParams}
     * map the controller returns alongside the rows.
     *
     * <p>Example: a procedure
     * {@code CALL proc(:in_id, :out_status, :out_message)}
     * with {@code OUT_PARAM_NAMES = "out_status,out_message"}.
     *
     * <p>Nullable and empty both mean "no OUT params" — the
     * procedure relies on {@code RETURN QUERY} for the result
     * set, the legacy behaviour.
     */
    @Column(name = "OUT_PARAM_NAMES", length = 500)
    private String outParamNames;

    /**
     * Author-declared JDBC/PG type per caller-controlled placeholder.
     * Shape: {@code {"PARAM.NOMBRE":"TEXT", "BODY.IDS":"BIGINT[]", ...}}.
     * Strict at write time: every {@code :PARAM.*} / {@code :BODY.*}
     * in the SQL must appear as a key. {@code :CONTEXT.*} and
     * {@code :QUERY.{SIZE,OFFSET}} are system-bound and need no entry.
     *
     * <p>Marshalled to JSONB by Hibernate 7 ({@link SqlTypes#JSON}).
     * {@link LinkedHashMap} preserves insertion order so the API
     * responses stay deterministic when the UI diffs by key.
     */
    @JdbcTypeCode(SqlTypes.JSON)
    @Column(name = "PARAM_TYPES", nullable = false, columnDefinition = "jsonb")
    private Map<String, String> paramTypes = new LinkedHashMap<>();

    /**
     * V81 — restricciones de formato opcionales por placeholder,
     * adicionales al tipo/obligatoriedad de {@link #paramTypes}.
     * Cada fila referencia esta query ({@code query_id} FK,
     * {@code ON DELETE CASCADE} en BD; {@code cascade=ALL,
     * orphanRemoval=true} aquí para que el lado Java se comporte
     * igual). {@code query-service} las consume vía
     * {@code QueryDefinition.paramConstraints()} para validar el
     * body/params antes del bind (ver
     * {@code com.co.eurekatic.common.query.ParamConstraintValidator}).
     *
     * <p>{@code QueryAdminService} reescribe el set completo en cada
     * create/update — ver {@link #replaceParamConstraints(java.util.Collection)}.
     */
    @OneToMany(mappedBy = "query", cascade = CascadeType.ALL,
            orphanRemoval = true, fetch = FetchType.LAZY)
    private List<QueryParamConstraint> paramConstraints = new ArrayList<>();

    /**
     * Reemplaza el set completo de restricciones de esta query —
     * misma intención que {@code setParamTypes} sobrescribiendo todo
     * el mapa en cada guardado, pero hecho como un DIFF por
     * {@code paramKey} en vez de {@code clear()} + re-add.
     *
     * <p><b>Por qué no {@code clear()} + re-add</b>: en un
     * {@code @OneToMany(orphanRemoval=true)}, Hibernate encola las
     * inserciones ANTES que los deletes de huérfanos dentro del mismo
     * flush. Si el autor edita una query sin cambiar los placeholders
     * (el caso común: editar la query, no tocar restricciones), el
     * {@code clear()} marca las filas viejas como huérfanas y el
     * re-add crea entidades NUEVAS con el mismo
     * {@code (query_id, param_key)} — el INSERT de la fila nueva
     * corre antes que el DELETE de la vieja y choca contra
     * {@code uq_query_param_constraint}. El diff evita el choque de
     * raíz: una key que sigue presente actualiza sus columnas EN LA
     * MISMA fila administrada (sin delete+insert), y sólo las keys
     * que de verdad desaparecen o aparecen generan un delete o un
     * insert real.
     */
    public void replaceParamConstraints(java.util.Collection<QueryParamConstraint> next) {
        java.util.Map<String, QueryParamConstraint> incoming = new java.util.LinkedHashMap<>();
        if (next != null) {
            for (QueryParamConstraint c : next) {
                incoming.put(c.getParamKey(), c);
            }
        }

        // 1) Quita del in-memory las keys que ya no vienen — orphanRemoval
        //    encola su DELETE al flush.
        this.paramConstraints.removeIf(existing -> !incoming.containsKey(existing.getParamKey()));

        // 2) Para las que siguen, actualiza los valores EN LA fila
        //    administrada existente — ni delete ni insert, sólo UPDATE.
        for (QueryParamConstraint existing : this.paramConstraints) {
            QueryParamConstraint updated = incoming.remove(existing.getParamKey());
            if (updated != null) {
                existing.setOnlyPositive(updated.getOnlyPositive());
                existing.setAllowDecimals(updated.getAllowDecimals());
                existing.setMaxDigits(updated.getMaxDigits());
                existing.setMinValue(updated.getMinValue());
                existing.setMaxValue(updated.getMaxValue());
                existing.setNumericText(updated.getNumericText());
                existing.setMinLength(updated.getMinLength());
                existing.setMaxLength(updated.getMaxLength());
            }
        }

        // 3) Lo que sobra en `incoming` son keys genuinamente nuevas —
        //    sólo estas generan un INSERT real.
        for (QueryParamConstraint fresh : incoming.values()) {
            fresh.setQuery(this);
            this.paramConstraints.add(fresh);
        }
    }
    /*
     * V110 — opt-in flag: when {@code true}, {@code query-service}
     * may serve this row's {@code GET} result from Redis instead of
     * re-running the SQL on every request. Default {@code false}
     * preserves pre-V110 behaviour for every existing row.
     *
     * <p>Deliberately opt-in and not blanket: a {@code GET} row can
     * carry {@code :CONTEXT.*} binds (userId/email/roles) and
     * caller-supplied query/path/body params, so caching is only
     * safe once the query author has actively decided the result is
     * reusable across identical requests for a bounded window. See
     * {@code query-service}'s {@code CatalogResultCacheService}.
     */
    @Column(name = "CACHEABLE", nullable = false)
    private boolean cacheable = false;

    /**
     * V110 — staleness window in seconds when {@link #cacheable} is
     * {@code true}. Ignored otherwise. Default 60s; the author picks
     * a wider window for near-static catalogs and a narrower one for
     * anything closer to live.
     *
     * <p><b>V66 — this is now an upper bound, not the typical
     * staleness.</b> {@code query-service} invalidates every cached
     * {@code GET} for its own instance as soon as a {@code PROCEDURE}
     * / {@code DML} row (or the legacy {@code /write} endpoint)
     * successfully mutates data — see {@code CatalogResultCacheService
     * #invalidateAll}. In the normal case a GET issued right after a
     * write already sees fresh data; {@code cacheTtlSeconds} only
     * matters as a ceiling for the case Redis itself is unreachable
     * at invalidation time (fail-open — the write still succeeds, the
     * cache entry just outlives it by up to this many seconds
     * instead of being cleared immediately).
     *
     * <p>The invalidation is instance-scoped and blunt on purpose:
     * ANY write clears ALL of this instance's cached GETs, not just
     * the ones the write actually affected — there's no catalog
     * metadata linking a write row to the reads it touches. Pick a
     * TTL as if that fine-grained mapping didn't exist; the
     * invalidation is a bonus that makes the common case feel
     * instant, not the mechanism you're meant to rely on for
     * correctness.
     */
    @Column(name = "CACHE_TTL_SECONDS", nullable = false)
    private int cacheTtlSeconds = 60;

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
