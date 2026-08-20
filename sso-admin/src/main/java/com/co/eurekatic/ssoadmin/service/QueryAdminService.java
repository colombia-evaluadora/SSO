package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Microservice;
import com.co.eurekatic.common.entity.Query;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.query.ParamNamespace;
import com.co.eurekatic.common.query.ParamTypes;
import com.co.eurekatic.common.query.PathTemplateSyntax;
import com.co.eurekatic.common.query.PlaceholderScanner;
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

import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.stream.Collectors;

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
        validateMethodAgainstSql(req);

        validatePathTemplate(req, null);
        validateOutParams(req);
        validateParamTypes(req);
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
        validateMethodAgainstSql(req);

        validatePathTemplate(req, q.getId());
        validateOutParams(req);
        validateParamTypes(req);
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
        String httpMethod = normalizeHttpMethod(req.httpMethod());
        q.setHttpMethod(httpMethod);
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
        // V49: author-declared JDBC/PG type per caller-controlled
        // placeholder. Strict validation lives in validateParamTypes(),
        // called from create()/update() before copy(). LinkedHashMap
        // to preserve insertion order for deterministic API responses.
        q.setParamTypes(new LinkedHashMap<>(req.paramTypes()));
        // V110: opt-in cache flag + TTL. A null cacheTtlSeconds
        // (back-compat callers, or a client that just checked the
        // "cacheable" box without touching the TTL field) falls
        // back to the entity's own default (60s) instead of writing
        // zero/negative into a column the DB CHECK requires positive.
        // Defense in depth: cacheable only makes sense for a GET
        // row (see Query#isCacheable's javadoc — POST/PUT/PATCH
        // mutate and must never be served from a stale cache entry).
        // QueryPathRegistry already refuses to carry a true flag
        // through for a non-GET row regardless, but rejecting it
        // here means the admin-ui form gets an immediate 400 instead
        // of a silently-ignored checkbox.
        if (req.cacheable() && !"GET".equals(httpMethod)) {
            throw new IllegalArgumentException(
                    "cacheable solo aplica a filas GET (httpMethod=" + httpMethod + ")");
        }
        q.setCacheable(req.cacheable());
        if (req.cacheTtlSeconds() != null) {
            if (req.cacheTtlSeconds() <= 0) {
                throw new IllegalArgumentException(
                        "cacheTtlSeconds debe ser mayor que cero (recibido: "
                                + req.cacheTtlSeconds() + ")");
            }
            q.setCacheTtlSeconds(req.cacheTtlSeconds());
        }
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
     * V49 — strict validation of {@code paramTypes} at write time.
     *
     * <p>Two checks, en este orden:
     *
     * <ol>
     *   <li><b>Shape</b>: cada clave debe ser un placeholder válido
     *       ({@link ParamTypes#isValidKey}) y cada valor un tipo del
     *       set curado ({@link ParamTypes#CURATED}). Una entrada mal
     *       formada se rechaza con 400 mencionando el set permitido.</li>
     *   <li><b>Cobertura</b>: todo placeholder {@code :PARAM.*} o
     *       {@code :BODY.*} presente en el SQL debe tener una entrada
     *       en {@code paramTypes}. {@code :CONTEXT.*} y
     *       {@code :QUERY.{SIZE,OFFSET}} son del sistema y no
     *       requieren entrada.</li>
     * </ol>
     *
     * <p>El mensaje de error nombra los placeholders sin tipo en
     * orden alfabético ({@link TreeSet}) para que el autor pueda
     * copiarlos a la UI sin reordenar.
     */
    private void validateParamTypes(QueryRequest req) {
        Map<String, String> raw = req.paramTypes() == null
                ? Map.of() : req.paramTypes();
        if (raw.isEmpty()) {
            // Aún sin tipos declarados, validamos la cobertura
            // (el SQL podría tener placeholders sin soportar
            // — debe ser 0 o todos declarados).
            validateCoverage(req.query(), Map.of());
            return;
        }

        // V60-bis — canonicalizamos keys a MAYÚSCULAS para
        // tolerar clientes (admins) que las escriban en
        // cualquier caja — la cobertura y el lookup en
        // query-service son case-insensitive desde V60-bis.
        Map<String, String> declared = new java.util.LinkedHashMap<>();
        for (Map.Entry<String, String> e : raw.entrySet()) {
            String upperKey = e.getKey().toUpperCase(java.util.Locale.ROOT);
            if (!ParamTypes.isValidKey(upperKey)) {
                throw new IllegalArgumentException(
                    "PARAM_TYPES key inválida: '" + e.getKey()
                    + "' (canonical='" + upperKey + "'). Cada segmento debe "
                    + "coincidir con [A-Z][A-Z0-9_]* (namespace incluido). "
                    + "Ejemplos válidos: 'PARAM.NOMBRE', 'BODY.USER.EMAIL'.");
            }
            // V62 — el valor puede traer el sufijo de obligatoriedad
            // ('!', ver ParamTypes#parseDeclaration); el set curado
            // sólo conoce el tipo base, así que se valida sin el
            // sufijo. El sufijo en sí no se restringe más — cualquier
            // tipo del set curado puede marcarse obligatorio.
            var declaracion = ParamTypes.parseDeclaration(e.getValue());
            String baseType = declaracion.baseType();
            if (!ParamTypes.CURATED.contains(baseType)) {
                throw new IllegalArgumentException(
                    "PARAM_TYPES['" + upperKey + "']='" + e.getValue()
                    + "' no es un tipo soportado. Permitidos: "
                    + ParamTypes.CURATED
                    + " (opcionalmente con sufijo '!' para marcarlo obligatorio, "
                    + "p. ej. 'BIGINT!').");
            }
            // V63 — FILE:clasificacion declara con qué carpeta S3
            // arma file-service la clave (ver ParamTypes.FILE). Sólo
            // se valida el FORMATO acá — un ':' en cualquier tipo que
            // no sea FILE ya se rechazó arriba (el baseType con ':'
            // incluido no está en CURATED, así que nunca llega hasta
            // acá para un tipo distinto).
            if (declaracion.fileClassification() != null
                    && !ParamTypes.isValidFileClassification(declaracion.fileClassification())) {
                throw new IllegalArgumentException(
                    "PARAM_TYPES['" + upperKey + "']='" + e.getValue()
                    + "' tiene una clasificación de archivo inválida: '"
                    + declaracion.fileClassification() + "'. Debe empezar con una "
                    + "letra y usar sólo letras, dígitos y '_' — ej. 'perfilUsuario', "
                    + "'PRIMER_PERIODO'.");
            }
            // V65 — FILE:clasificacion:campoEstablecimiento agrega un
            // tercer componente: el campo de texto del multipart que
            // trae el código de establecimiento a anteponer en la
            // clave S3 (ver ParamTypes.ESTABLISHMENT_SCOPED_FILE_CLASSIFICATIONS).
            // Sólo tiene sentido junto a una clasificación — si el
            // parseo lo llenó sin clasificación (no puede pasar hoy,
            // el separador es el mismo y el primero gana la
            // clasificación, pero se deja explícito por si el formato
            // cambia) se rechaza igual que un formato inválido.
            if (declaracion.fileEstablishmentField() != null
                    && !ParamTypes.isValidFileEstablishmentField(declaracion.fileEstablishmentField())) {
                throw new IllegalArgumentException(
                    "PARAM_TYPES['" + upperKey + "']='" + e.getValue()
                    + "' tiene un campo de establecimiento inválido: '"
                    + declaracion.fileEstablishmentField() + "'. Debe empezar con una "
                    + "letra y usar sólo letras, dígitos y '_' — ej. 'idEstablecimiento'.");
            }
            // Detectar colisiones case-only entre keys
            // (ej. "body.id" y "BODY.ID" envían a la misma
            // key canónica).
            String prev = declared.putIfAbsent(upperKey, e.getValue());
            if (prev != null) {
                throw new IllegalArgumentException(
                    "PARAM_TYPES tiene las dos claves '" + e.getKey()
                    + "' y '" + prev + "' que difieren sólo por mayúsculas. "
                    + "Envía sólo una (la forma canónica es '" + upperKey + "').");
            }
        }

        validateCoverage(req.query(), declared);
    }

    private void validateCoverage(String sql, Map<String, String> declared) {
        Set<String> inSql = sql == null ? Set.of() : PlaceholderScanner.scan(sql);
        Set<String> required = inSql.stream()
                .filter(p -> {
                    String ns = p.split("\\.", 2)[0];
                    return ParamNamespace.PARAM.equals(ns)
                            || ParamNamespace.BODY.equals(ns)
                            || ParamNamespace.BODY_RAW.equals(ns);
                })
                .collect(Collectors.toCollection(TreeSet::new));

        // La cobertura es case-insensitive — los placeholders
        // del SQL pueden estar en cualquier caja (el rewriter
        // los uppercase-es para el lookup) y las keys de
        // paramTypes están canonicalizadas.
        Set<String> declaredUpper = declared.keySet().stream()
                .map(s -> s.toUpperCase(java.util.Locale.ROOT))
                .collect(Collectors.toCollection(TreeSet::new));
        Set<String> requiredUpper = required.stream()
                .map(s -> s.toUpperCase(java.util.Locale.ROOT))
                .collect(Collectors.toCollection(TreeSet::new));
        Set<String> missing = new TreeSet<>(requiredUpper);
        missing.removeAll(declaredUpper);
        if (!missing.isEmpty()) {
            throw new IllegalArgumentException(
                "PARAM_TYPES incompleto. Placeholders del SQL sin tipo "
                + "declarado: " + missing
                + ". Asigna un tipo a cada uno antes de guardar "
                + "(o usa 'TEXT' si no tienes preferencia).");
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
        // V33 — la comprobación incluye el verbo. Sin él,
        // GET /est/:ID se rechazaba como duplicado de un
        // PUT /est/:ID existente, aunque el índice de BD sí los
        // admite. El síntoma era un 409 imposible de entender
        // desde el formulario.
        String method = normalizeHttpMethod(req.httpMethod());
        boolean taken = queryRepo.existsByMicroservice_IdAndPathTemplateAndHttpMethod(
                req.microserviceId(), tpl, method);
        if (taken) {
            // exempt the row being updated
            if (excludeId == null
                    || queryRepo.findById(excludeId)
                            .map(q -> !(tpl.equals(q.getPathTemplate())
                                    && method.equals(q.getHttpMethod())))
                            .orElse(true)) {
                throw new DuplicateException("Query.pathTemplate", method + " " + tpl);
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
        // DML directo. Deliberadamente NO se concede relajando
        // rejectIfMutating "cuando el método es POST o PUT": como
        // HTTP_METHOD entra con default POST, eso habría dejado sin
        // guardia a todas las filas que ya existen, en el mismo
        // despliegue y sin que nadie las tocara. Atarlo al modo hace
        // que el permiso alcance sólo a las filas donde el autor
        // escribió DML a propósito; una fila SELECT sigue pasando
        // por el guardia igual que siempre.
        if (first.equals("INSERT") || first.equals("UPDATE")) {
            return "DML";
        }
        // DELETE y el DDL quedan fuera. Es la misma línea que ya
        // traza WriteService, cuyo enum sólo admite INSERT y UPDATE.
        throw new IllegalArgumentException(
                "El SQL debe empezar por SELECT, WITH, CALL, INSERT o UPDATE; "
                + "empieza por '" + first + "'. Para borrar o alterar "
                + "estructura, publica un procedimiento y llámalo con CALL.");
    }

    /** Verbos admitidos. DELETE queda fuera a propósito — ver la entidad Query. */
    private static final Set<String> HTTP_METHODS = Set.of("GET", "POST", "PUT", "PATCH");

    /**
     * Normaliza y valida el verbo. Null o vacío cae a {@code POST},
     * que es lo que hacían todas las rutas antes de V33, para que un
     * cliente que no mande el campo no cambie de comportamiento.
     */
    static String normalizeHttpMethod(String raw) {
        if (raw == null || raw.isBlank()) {
            return "POST";
        }
        String m = raw.trim().toUpperCase(java.util.Locale.ROOT);
        if (!HTTP_METHODS.contains(m)) {
            throw new IllegalArgumentException(
                    "Método HTTP no admitido: '" + raw + "'. Usa GET, POST, PUT o PATCH. "
                    + "DELETE no se admite; para borrar, publica un "
                    + "procedimiento y llámalo con CALL.");
        }
        return m;
    }

    /**
     * Comprobaciones que cruzan el verbo con el SQL. Se hacen al
     * guardar y no en tiempo de petición: aquí hay un humano
     * mirando el formulario, allí sólo un 500 en un log.
     */
    private void validateMethodAgainstSql(QueryRequest req) {
        String method = normalizeHttpMethod(req.httpMethod());
        String mode = deriveExecutionMode(req.query());
        String sql = req.query() == null ? "" : req.query();

        // Un GET no lleva cuerpo, así que :BODY.* nunca tendría
        // valor. Mejor decirlo ahora que dejar un bind sin resolver
        // esperando a la primera llamada real.
        if ("GET".equals(method) && sql.toUpperCase(java.util.Locale.ROOT).contains(":BODY.")) {
            throw new IllegalArgumentException(
                    "Un GET no lleva cuerpo, así que no puede usar :BODY.*. "
                    + "Pasa esos valores por la ruta (:PARAM.*) o por el "
                    + "query string (:QUERY.*).");
        }
        // Un GET no debe modificar nada. Es la mitad del contrato
        // que hace que un GET se pueda cachear y reintentar.
        // PATCH sí admite DML (es la esencia del partial update).
        if ("GET".equals(method) && "DML".equals(mode)) {
            throw new IllegalArgumentException(
                    "Un GET no puede ejecutar INSERT ni UPDATE. Ata esta "
                    + "consulta a POST, PUT o PATCH.");
        }
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
