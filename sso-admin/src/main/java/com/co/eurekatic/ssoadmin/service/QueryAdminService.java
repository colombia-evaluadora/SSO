package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Microservice;
import com.co.eurekatic.common.entity.Query;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.query.PathTemplateSyntax;
import com.co.eurekatic.common.repository.MicroserviceRepository;
import com.co.eurekatic.common.repository.QueryRepository;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.ssoadmin.dto.QueryRequest;
import com.co.eurekatic.ssoadmin.dto.QueryResponse;
import com.co.eurekatic.ssoadmin.exception.DuplicateException;
import com.co.eurekatic.ssoadmin.exception.NotFoundException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/**
 * Query CRUD plus role bindings. Mirrors the shape of
 * {@link EndpointService} so the admin UI can use the same
 * patterns (list + create + update + delete + bind/unbind
 * role). The catalog endpoint on the read side (see
 * {@code QueryCatalogController}) is what {@code query-service}
 * calls — it does NOT go through this service.
 *
 * <p>Uniqueness: the legacy rule is {@code uuid}. We pre-check
 * with {@link QueryRepository#existsByUuid} for a friendlier
 * 409; the DB-level {@code UQ_QUERY_UUID} constraint is the
 * real source of truth under concurrent inserts.
 *
 * <p>UID automático: si el request llega sin {@code uuid}, el
 * create genera uno ({@code UUID.randomUUID()}) y el update
 * conserva el de la fila. Un uuid explícito se sigue respetando,
 * así que las importaciones y las filas legacy con handle con
 * significado no cambian de comportamiento.
 *
 * <p>Microservice binding: a non-null
 * {@link QueryRequest#microserviceId()} is resolved via
 * {@link MicroserviceRepository#findById} and the lookup MUST
 * yield a {@code kind=QUERY} row — REST rows have no container
 * to serve the SQL, so binding a query to one is a user error
 * we surface as 422 rather than letting the request pass and
 * hit a runtime failure on the first {@code /query} call.
 */
@Service
public class QueryAdminService {

    private static final Logger log = LoggerFactory.getLogger(QueryAdminService.class);

    private final QueryRepository queryRepo;
    private final RoleRepository roleRepo;
    private final MicroserviceRepository microserviceRepo;
    private final PathRegistryNotifier pathRegistryNotifier;

    public QueryAdminService(QueryRepository queryRepo,
                             RoleRepository roleRepo,
                             MicroserviceRepository microserviceRepo,
                             PathRegistryNotifier pathRegistryNotifier) {
        this.queryRepo = queryRepo;
        this.roleRepo = roleRepo;
        this.microserviceRepo = microserviceRepo;
        this.pathRegistryNotifier = pathRegistryNotifier;
    }

    @Transactional
    public QueryResponse create(QueryRequest req) {
        String uuid = resolveUuidForCreate(req.uuid());
        if (queryRepo.existsByUuid(uuid)) {
            throw new DuplicateException("Query", uuid);
        }
        validatePathTemplate(req, null);
        validateOutParams(req);
        Query q = new Query();
        copy(req, q, uuid);
        QueryResponse response = QueryResponse.fromEntity(queryRepo.save(q));
        // V33 — push the change to query-service so the
        // path-registry picks up the new row before the
        // next 60s tick. Best-effort (the notifier logs
        // and swallows failures; the periodic refresh
        // is the safety net).
        pathRegistryNotifier.invalidate();
        return response;
    }

    @Transactional
    public QueryResponse update(QueryRequest req) {
        if (req.id() == null) {
            throw new IllegalArgumentException("El id es obligatorio para actualizar");
        }
        Query q = queryRepo.findById(req.id())
                .orElseThrow(() -> new NotFoundException("Query", req.id()));
        // uuid en blanco = "no lo toques". Es el handle público que
        // los consumidores ya tienen cableado, así que un update sin
        // uuid conserva el de la fila en vez de generar uno nuevo.
        String uuid = isBlank(req.uuid()) ? q.getUuid() : req.uuid().trim();
        // Allow same uuid only for the same row.
        queryRepo.findByUuid(uuid).ifPresent(existing -> {
            if (!existing.getId().equals(q.getId())) {
                throw new DuplicateException("Query", uuid);
            }
        });
        validatePathTemplate(req, q.getId());
        validateOutParams(req);
        copy(req, q, uuid);
        QueryResponse response = QueryResponse.fromEntity(queryRepo.save(q));
        // V33 — same invalidate-on-write as create().
        pathRegistryNotifier.invalidate();
        return response;
    }

    @Transactional(readOnly = true)
    public List<QueryResponse> getAll() {
        return queryRepo.findAll().stream()
                .map(QueryResponse::fromEntity)
                .toList();
    }

    @Transactional(readOnly = true)
    public QueryResponse getById(Long id) {
        return QueryResponse.fromEntity(queryRepo.findById(id)
                .orElseThrow(() -> new NotFoundException("Query", id)));
    }

    @Transactional
    public void delete(Long id) {
        if (!queryRepo.existsById(id)) {
            throw new NotFoundException("Query", id);
        }
        queryRepo.deleteById(id);
        // V33 — delete also invalidates so a removed
        // path-template stops being served immediately.
        pathRegistryNotifier.invalidate();
    }

    /* ====================== bindings: role ====================== */

    @Transactional
    public void bindRole(Long queryId, Long roleId) {
        Query q = queryRepo.findById(queryId)
                .orElseThrow(() -> new NotFoundException("Query", queryId));
        Role r = roleRepo.findById(roleId)
                .orElseThrow(() -> new NotFoundException("Role", roleId));
        q.addRole(r);
    }

    @Transactional
    public void unbindRole(Long queryId, Long roleId) {
        Query q = queryRepo.findById(queryId)
                .orElseThrow(() -> new NotFoundException("Query", queryId));
        Role r = roleRepo.findById(roleId)
                .orElseThrow(() -> new NotFoundException("Role", roleId));
        q.removeRole(r);
    }

    /**
     * Compact DTO matching the {@code EndpointService.RoleChecked}
     * shape: id plus a flag telling the admin UI whether the
     * role is currently bound to the query. The field names use
     * the suffixed convention ({@code roleId} + {@code checked})
     * to match the rest of the module — see AppService, the
     * admin-ui QueryRoleChecked type, and the
     * {@code admin-ui/scripts/smoke-query-roles.sh} contract.
     *
     * <p>An earlier draft used bare {@code id} and {@code bound};
     * the admin-ui binding tab was silently rendering
     * {@code data-testid="role-toggle-undefined"} and firing
     * {@code POST /query/{id}/role/undefined} because the JSON
     * parser read {@code row.roleId} as undefined.
     */
    public record RoleChecked(Long roleId, String name, boolean checked) {}

    @Transactional(readOnly = true)
    public List<RoleChecked> getRolesForQueryChecked(Long queryId) {
        Query q = queryRepo.findById(queryId)
                .orElseThrow(() -> new NotFoundException("Query", queryId));
        Set<Long> bound = q.getRoles().stream()
                .map(Role::getId)
                .collect(java.util.stream.Collectors.toCollection(LinkedHashSet::new));
        return roleRepo.findAll().stream()
                .map(r -> new RoleChecked(r.getId(), r.getName(), bound.contains(r.getId())))
                .toList();
    }

    /* ====================== helpers ====================== */

    /**
     * UID automático: el catálogo genera el handle cuando el
     * cliente no manda uno. Se sigue aceptando un uuid explícito
     * (importaciones, filas legacy con uuid con significado); el
     * admin-ui simplemente no lo envía al crear.
     */
    private static String resolveUuidForCreate(String requested) {
        return isBlank(requested)
                ? java.util.UUID.randomUUID().toString()
                : requested.trim();
    }

    private static boolean isBlank(String s) {
        return s == null || s.isBlank();
    }

    private void copy(QueryRequest req, Query q, String uuid) {
        q.setUuid(uuid);
        q.setQuery(req.query());
        // El dialecto lo declara el microservicio dueño, así que el
        // admin no tiene por qué teclearlo. Antes el formulario lo
        // pedía como "Tipo" describiéndolo como etiqueta opcional
        // — y no lo era: TYPE elige el NamedParameterJdbcTemplate y
        // la clave de bulkhead en query-service. Escribir "CHART"
        // ahí, como sugería la ayuda, producía un 502 la primera
        // vez que se invocaba la query.
        q.setType(resolveDialect(req));
        q.setPublicEnd(req.publicEnd());
        q.setCaptcha(req.captcha());
        q.setDetail(req.detail());
        q.setAction(req.action());
        q.setStyle(req.style());
        // Derivado del SQL, no pedido al admin. Ver
        // deriveExecutionMode para por qué el campo sobraba.
        q.setExecutionMode(deriveExecutionMode(req.query()));
        // V27: nullable. When set, the unique partial index
        // (microservice_id, path_template) catches concurrent
        // insert races; the service-layer check below catches
        // the in-band case for a friendlier 409.
        q.setPathTemplate(normalizePathTemplate(req.pathTemplate()));
        // V31: comma-separated :placeholder names that are
        // OUT params of a PROCEDURE-mode row. Validation lives
        // in validateOutParams() (must contain a placeholder
        // that exists in the SQL; only meaningful for PROCEDURE).
        q.setOutParamNames(normalizeOutParams(req.outParamNames()));
        // Resolve microservice binding. Null clears the
        // association (back to "global" — any instance may
        // serve). A non-null id MUST resolve to a kind=QUERY
        // row; binding a query to a REST row is meaningless
        // because there is no container to execute the SQL.
        // We throw 422 (Unprocessable) rather than 400 because
        // the request itself is well-formed; the referenced
        // entity is just wrong.
        q.setMicroservice(resolveQueryMicroservice(req.microserviceId()));
    }

    /**
     * V31 — normalize the comma-separated OUT param names.
     * Empty / whitespace becomes {@code null} (legacy
     * behavior). Each non-empty token must start with
     * ":" (it has to match a SQL placeholder) and must
     * appear as a {@code :name} token in the SQL body.
     * Only meaningful for {@code PROCEDURE} mode — set on
     * a {@code SELECT} / {@code FUNCTION} row is rejected.
     */
    private static String normalizeOutParams(String raw) {
        if (raw == null) return null;
        String trimmed = raw.trim();
        if (trimmed.isEmpty()) return null;
        // Normalize whitespace: "out_a , out_b" → "out_a,out_b"
        return java.util.Arrays.stream(trimmed.split(","))
                .map(String::trim)
                .filter(s -> !s.isEmpty())
                .collect(java.util.stream.Collectors.joining(","));
    }

    private void validateOutParams(QueryRequest req) {
        String outParams = req.outParamNames();
        if (outParams == null || outParams.isBlank()) {
            return;
        }
        // El modo ya no lo declara el request: se deriva del SQL,
        // así que aquí se pregunta a la misma función que decide.
        // Preguntar a req.executionMode() dejaría esta validación
        // mirando un campo que el formulario ya no envía.
        String mode = deriveExecutionMode(req.query());
        if (!"PROCEDURE".equals(mode)) {
            throw new IllegalArgumentException(
                "outParamNames sólo aplica a procedimientos (SQL que empieza "
                + "por CALL); este SQL se ejecuta como " + mode + ".");
        }
        // Each name must look like a placeholder and appear in the SQL.
        String sql = req.query() == null ? "" : req.query();
        for (String name : outParams.split(",")) {
            String token = name.trim();
            if (token.isEmpty()) continue;
            if (!token.startsWith(":")) {
                throw new IllegalArgumentException(
                    "outParamNames entries must start with ':' (placeholder); got: " + token);
            }
            // Must appear in the SQL. Tolerate spaces around
            // the colon (PostgreSQL accepts `: name` too).
            String needle = ":" + token.substring(1);
            if (!sql.contains(needle)) {
                throw new IllegalArgumentException(
                    "outParamNames entry " + token + " does not appear as a placeholder "
                    + "in the query SQL");
            }
        }
    }

    /**
     * V27 — normalize and validate the path template. Empty /
     * whitespace becomes {@code null} (the legacy / non-path
     * mode). Non-empty must start with "/" and must not contain
     * "**" (the gateway splits on the prefix, so a "**" inside a
     * per-query template would never match a real URL).
     *
     * <p>{@code excludeId} is the row being updated — we allow
     * the same row to keep its own pathTemplate without tripping
     * the unique index. The pre-check here is also friendlier
     * than the DB's constraint violation.
     */
    private void validatePathTemplate(QueryRequest req, Long excludeId) {
        String tpl = normalizePathTemplate(req.pathTemplate());
        if (tpl == null) {
            return;
        }
        if (req.microserviceId() == null) {
            throw new IllegalArgumentException(
                "pathTemplate requires microserviceId (queries without a "
                + "backing microservice cannot have a URL-suffix)");
        }
        // Gramática compartida con query-service (módulo common):
        // si cada lado tuviera su propia validación, una plantilla
        // podría guardarse aquí y no casar allí — y ese fallo no
        // produce error, produce 200 con lista vacía.
        PathTemplateSyntax.validate(tpl);
        // Reject if another query in the same microservice already
        // claims this path. The DB partial unique index catches
        // the race; this catches the in-band duplicate for a
        // clearer 409 message.
        boolean taken = queryRepo.existsByMicroservice_IdAndPathTemplate(
                req.microserviceId(), tpl);
        if (taken) {
            // exempt the row being updated
            if (excludeId == null
                    || queryRepo.findById(excludeId)
                            .map(q -> !tpl.equals(q.getPathTemplate()))
                            .orElse(true)) {
                throw new DuplicateException("Query.pathTemplate", tpl);
            }
        }
    }

    /**
     * Deduce el modo de ejecución del primer keyword del SQL.
     *
     * <p>Antes esto era un campo del formulario y el backend se
     * limitaba a comprobar que coincidiera con el SQL: se le pedía
     * al admin un dato que el sistema ya podía leer, y luego se le
     * reñía si no acertaba.
     *
     * <p>FUNCTION desaparece como modo. No aportaba comportamiento:
     * {@code QueryService} lo trataba con el mismo {@code if} que
     * SELECT (una función se invoca como {@code SELECT * FROM f()})
     * y la validación le exigía el mismo primer keyword. Era una
     * opción más que equivocar, sin efecto alguno.
     *
     * <p>Package-private y estático para poder probarlo sin montar
     * el servicio con todos sus repositorios.
     */
    static String deriveExecutionMode(String rawSql) {
        String sql = rawSql == null ? "" : rawSql.stripLeading();
        // Misma tolerancia a comentarios iniciales que tenía
        // validateExecutionModePrefix, al que sustituye.
        while (sql.startsWith("--")) {
            int nl = sql.indexOf('\n');
            if (nl < 0) { sql = ""; break; }
            sql = sql.substring(nl + 1).stripLeading();
        }
        if (sql.isEmpty()) {
            throw new IllegalArgumentException("El SQL no puede estar vacío.");
        }
        String first = sql.split("\\s+", 2)[0].toUpperCase(java.util.Locale.ROOT);
        if (first.equals("CALL")) {
            return "PROCEDURE";
        }
        if (first.equals("SELECT") || first.equals("WITH")) {
            return "SELECT";
        }
        throw new IllegalArgumentException(
                "El SQL debe empezar por SELECT, WITH o CALL; empieza por '"
                + first + "'. Para escribir o borrar datos usa una "
                + "definición de escritura, no una query.");
    }

    /**
     * Dialecto heredado del microservicio dueño. Sin microservicio
     * se conserva el comportamiento previo: null, que
     * {@code JdbcTemplateRegistry.resolve} interpreta como
     * "postgres".
     */
    private String resolveDialect(QueryRequest req) {
        if (req.microserviceId() == null) {
            return null;
        }
        return microserviceRepo.findById(req.microserviceId())
                .map(Microservice::getDialect)
                .orElse(null);
    }

    private static String normalizePathTemplate(String tpl) {
        if (tpl == null) return null;
        String trimmed = tpl.trim();
        return trimmed.isEmpty() ? null : trimmed;
    }

    /**
     * Looks up the microservice referenced by the request,
     * enforcing {@code kind=QUERY}. Returns {@code null} when
     * the request passed {@code null} (clear binding / global).
     *
     * @throws IllegalArgumentException if the id is non-null
     *         but does not exist, OR the row exists but is
     *         not a QUERY kind. Both map to 422 INVALID_REQUEST.
     */
    private Microservice resolveQueryMicroservice(Long microserviceId) {
        if (microserviceId == null) return null;
        Microservice m = microserviceRepo.findById(microserviceId)
                .orElseThrow(() -> new IllegalArgumentException(
                        "microserviceId " + microserviceId + " no existe"));
        if (!"QUERY".equals(m.getKind())) {
            throw new IllegalArgumentException(
                    "microserviceId " + microserviceId
                            + " es kind=" + m.getKind()
                            + "; los queries solo se vinculan a kind=QUERY");
        }
        return m;
    }
}
