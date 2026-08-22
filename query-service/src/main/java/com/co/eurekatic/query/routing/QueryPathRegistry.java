package com.co.eurekatic.query.routing;

import com.co.eurekatic.common.query.PathTemplateSyntax;
import com.co.eurekatic.query.catalog.CatalogClient;
import com.co.eurekatic.query.catalog.QueryDefinition;
import com.co.eurekatic.query.observability.QueryMetrics;
import jakarta.annotation.PostConstruct;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.server.PathContainer;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.web.util.pattern.PathPattern;
import org.springframework.web.util.pattern.PathPatternParser;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/**
 * V27 — in-memory {@code Map<pathTemplate, uuid>} the
 * {@code QueryPathController} consults to resolve an
 * incoming request's path to a catalog uuid. Loaded from
 * sso-admin's catalog at startup and refreshed periodically
 * (default 60s; configurable via
 * {@code query.path-registry.refresh-ms}).
 *
 * <p>Concurrency: reads happen on every request, writes
 * happen on a single scheduled thread. We swap the entire
 * map atomically via {@link AtomicReference} — readers see
 * either the old or the new table, never a partial
 * overwrite. The pattern is the standard "copy on write"
 * idiom for hot-read / rare-write maps.
 *
 * <p>This is per-instance state: each query-service
 * container maintains its own registry. The catalog is the
 * shared source of truth; refresh keeps every instance
 * eventually consistent. {@code @Scheduled} runs on a
 * single-thread scheduler per JVM, so there's no race
 * between two refresh ticks in the same process.
 */
@Component
public class QueryPathRegistry {

    private static final Logger log = LoggerFactory.getLogger(QueryPathRegistry.class);

    private final CatalogClient catalog;
    private final QueryMetrics metrics;
    /**
     * PathPatternParser en vez de AntPathMatcher por dos razones.
     *
     * <p>La primera es correctitud: {@code matchAndExtract} devuelve
     * las variables YA DECODIFICADAS. Con AntPathMatcher el valor
     * llegaba percent-encoded hasta la SQL, así que
     * {@code /establecimiento/PRUDENCIA%20DAZA} bindeaba el literal
     * "PRUDENCIA%20DAZA" — y como la consulta usa LIKE, ese '%' hacía
     * además de comodín. Resultado: 200 con lista vacía, nunca un
     * error. Cualquier nombre con espacio o acento era inalcanzable.
     *
     * <p>La segunda es que es la API que usa el propio Spring MVC;
     * AntPathMatcher está en retirada para matching de peticiones.
     *
     * <p>Se decodifica la VARIABLE EXTRAÍDA, no la ruta completa
     * antes de casar: decodificar antes permitiría que un %2F dentro
     * de un valor inyectara segmentos y casara una plantilla que no
     * corresponde. PathPattern hace exactamente eso.
     */
    private static final PathPatternParser PARSER = new PathPatternParser();
    private final AtomicReference<Map<RouteKey, RouteEntry>> tableRef =
            new AtomicReference<>(Map.of());

    /**
     * V33 — la clave del registro pasa de la plantilla sola a
     * (verbo, plantilla). Es lo que permite que
     * {@code GET /est/:ID} y {@code PUT /est/:ID} sean dos filas
     * distintas sobre la misma ruta.
     */
    public record RouteKey(String method, String template) {}

    /**
     * V110 — lo que el registro guarda por ruta, además del uuid:
     * el opt-in de cache y su TTL, tal cual los declaró el autor
     * de la fila en el catálogo. Viajan junto al uuid porque
     * {@link QueryPathController} los necesita en el momento del
     * dispatch, sin un segundo round-trip al catálogo.
     */
    public record RouteEntry(String uuid, boolean cacheable, int cacheTtlSeconds) {}
    private final String instanceName;
    /**
     * V32 — resolved at boot via {@code /internal/whoami}.
     * Null when the catalog has no row for our instance
     * name (registry stays scoped to "global" — every
     * path-template query, including rows owned by other
     * instances). Path uniqueness is per-microserviceId,
     * so two instances answering for the same template is
     * impossible.
     */
    private final AtomicLong myMicroserviceId = new AtomicLong(-1L);

    public QueryPathRegistry(CatalogClient catalog,
                             QueryMetrics metrics,
                             @Value("${query.instance.name:#{null}}") String instanceName) {
        this.catalog = catalog;
        this.metrics = metrics;
        this.instanceName = instanceName;
    }

    /**
     * Register the size gauge once at startup so dashboards
     * have a continuous view of registry population. The
     * gauge reads {@code tableRef.get()} lazily on each
     * scrape — cheap and always current.
     */
    @PostConstruct
    void registerSizeGauge() {
        metrics.registerRegistrySizeGauge(() -> tableRef.get().size());
    }

    /**
     * V32 — resolve our own {@code microserviceId} from the
     * catalog at boot. We need the instance name to be set
     * (the provisioner passes {@code QUERY_INSTANCE_NAME}
     * when it creates the container). When unset or the
     * catalog has no matching row, we fall back to
     * "global" (microserviceId=-1 → the periodic refresh
     * passes {@code null} to fetchPathTemplates).
     *
     * <p>Failure mode is graceful: if sso-admin is
     * unreachable at boot time, the registry keeps
     * working with the global scope and the periodic
     * refresh can discover our id later (the
     * {@code myMicroserviceId} value is updated each tick).
     */
    private void resolveMyMicroserviceId() {
        if (instanceName == null || instanceName.isBlank()) {
            log.info("QueryPathRegistry: no query.instance.name; staying global");
            return;
        }
        try {
            Map<String, Object> who = catalog.whoami(instanceName);
            Object idObj = who.get("microserviceId");
            if (idObj instanceof Number n) {
                long id = n.longValue();
                myMicroserviceId.set(id);
                log.info("QueryPathRegistry: resolved microserviceId={} for instanceName={}",
                        id, instanceName);
            } else {
                log.info("QueryPathRegistry: no microservice row for instanceName={}; "
                        + "staying global", instanceName);
            }
        } catch (Exception e) {
            log.warn("QueryPathRegistry: whoami failed; staying global: {}",
                    e.getMessage());
        }
    }

    /**
     * Initial load — fires at startup so the registry is
     * warm before the first request arrives. A failure here
     * logs at WARN; the registry stays empty and the
     * controller returns 404 for every path request until
     * the periodic refresh succeeds. Better to start
     * degraded than to refuse to start.
     */
    @Scheduled(fixedDelayString = "${query.path-registry.refresh-ms:60000}",
               initialDelay = 0)
    public void refresh() {
        // V32 — re-resolve our microserviceId on every
        // tick. Cheap (one HTTP roundtrip to /internal/whoami)
        // and means a fresh deploy of sso-admin's catalog
        // picks up the assignment without a query-service
        // restart.
        resolveMyMicroserviceId();
        try {
            Map<RouteKey, RouteEntry> next = new LinkedHashMap<>();
            // V30+V32 — call the dedicated internal endpoint
            // /internal/pathTemplates (server-side filtered to
            // rows with a non-null pathTemplate). Auth is the
            // shared X-Internal-Token header. We pass our
            // resolved microserviceId so the registry only
            // contains templates WE should answer for; rows
            // for other instances are excluded server-side.
            Long id = myMicroserviceId.get() < 0 ? null : myMicroserviceId.get();
            List<QueryDefinition> templates = catalog.fetchPathTemplates(id);
            for (QueryDefinition q : templates) {
                if (q.pathTemplate() != null && !q.pathTemplate().isBlank()) {
                    // Null cae a POST: es el verbo que tenían todas
                    // las rutas antes de V33, así que una fila que
                    // venga de un catálogo sin migrar sigue igual.
                    String method = q.httpMethod() == null || q.httpMethod().isBlank()
                            ? "POST"
                            : q.httpMethod().trim().toUpperCase(java.util.Locale.ROOT);
                    // V110 — cacheable is meaningful for GET rows
                    // only; QueryPathController additionally never
                    // caches a non-GET dispatch regardless of this
                    // flag, but we also refuse to carry it through
                    // here so a catalog author's mistake (marking a
                    // POST/PUT/PATCH row cacheable) can't even reach
                    // the controller as true.
                    boolean cacheable = "GET".equals(method) && q.cacheable();
                    next.put(new RouteKey(method, q.pathTemplate()),
                            new RouteEntry(q.uuid(), cacheable, q.cacheTtlSeconds()));
                }
            }
            tableRef.set(Map.copyOf(next));
            log.info("QueryPathRegistry: {} path templates loaded for instance={} (microserviceId={})",
                    next.size(), instanceName, id);
            metrics.recordRegistryRefresh(QueryMetrics.Outcome.SUCCESS, next.size());
        } catch (Exception e) {
            log.warn("QueryPathRegistry refresh failed (keeping previous {} entries): {}",
                    tableRef.get().size(), e.getMessage());
            metrics.recordRegistryRefresh(QueryMetrics.Outcome.FAILURE, 0);
        }
    }

    /**
     * Match an incoming path against the registered templates.
     *
     * <p>Antes esto devolvía el primer match en orden de
     * iteración, con el comentario de que "el autor del
     * catálogo declara las plantillas más específicas
     * primero". Ese contrato era imposible de cumplir: el
     * orden de iteración es el de {@code next.put(...)} en
     * {@link #refresh()}, que sigue el orden en que
     * {@code fetchPathTemplates} devuelve las filas (en la
     * práctica, {@code id_query} ascendente) — nada que el
     * autor controle desde el formulario del catálogo. El
     * síntoma real: {@code PUT /grados/:ID} (id 58) shadowa
     * para siempre a {@code PUT /grados/eliminacion-masiva}
     * (id 69) porque {@code :ID} matchea el literal
     * "eliminacion-masiva" igual de bien que un id real, y 58
     * se insertó antes que 69. Mismo bug con
     * {@code PUT /establecimientos/sedes/:ID} (92) tapando
     * {@code PUT /establecimientos/sedes/bulk-delete} (96).
     * Ambos endpoints bulk quedaban inalcanzables en
     * producción, no sólo en el harness de pruebas.
     *
     * <p>Ahora se recorren TODOS los templates del método y se
     * queda con el que extrajo MENOS variables de ruta — un
     * template sin {@code :VAR} es estrictamente más
     * específico que uno con, así que "menos variables" es un
     * proxy correcto de especificidad sin tener que enseñarle
     * a {@code PathPattern} nada de scoring. En empate (dos
     * templates con la misma cantidad de variables que
     * matchean la misma ruta — ambigüedad real de catálogo, no
     * shadowing) gana el primero en orden de iteración, igual
     * que antes.
     */
    public Optional<Match> match(String method, String path) {
        Optional<Match> result = matchAgainst(tableRef.get(), method, path);
        metrics.recordRegistryMatch(result.isPresent()
                ? QueryMetrics.Match.HIT : QueryMetrics.Match.MISS);
        return result;
    }

    /**
     * La lógica de {@link #match(String, String)} sin la
     * dependencia de {@link #tableRef} ni de {@link #metrics}, para
     * poder probarla contra una tabla armada a mano — igual que
     * {@link #matchTemplate} deja la gramática probable sin montar
     * el contexto de Spring.
     */
    static Optional<Match> matchAgainst(Map<RouteKey, RouteEntry> table, String method, String path) {
        if (path == null || path.isEmpty()) {
            return Optional.empty();
        }
        RouteEntry best = null;
        Map<String, String> bestVars = null;
        int bestSpecificity = Integer.MAX_VALUE;
        for (Map.Entry<RouteKey, RouteEntry> e : table.entrySet()) {
            if (!e.getKey().method().equals(method)) {
                continue;
            }
            Optional<Map<String, String>> vars = matchTemplate(e.getKey().template(), path);
            if (vars.isPresent() && vars.get().size() < bestSpecificity) {
                bestSpecificity = vars.get().size();
                best = e.getValue();
                bestVars = vars.get();
            }
        }
        return best == null
                ? Optional.empty()
                : Optional.of(new Match(best.uuid(), bestVars, best.cacheable(), best.cacheTtlSeconds()));
    }

    /**
     * ¿Existe la ruta con OTRO verbo? Sirve para distinguir un 405
     * de un 404: la URL existe, lo que no se admite es el método.
     * Un 404 haría pensar que la ruta está mal escrita.
     */
    public boolean pathExistsWithAnotherMethod(String method, String path) {
        if (path == null || path.isEmpty()) {
            return false;
        }
        return tableRef.get().keySet().stream()
                .filter(k -> !k.method().equals(method))
                .anyMatch(k -> matchTemplate(k.template(), path).isPresent());
    }

    /**
     * Casa una plantilla {@code :VARIABLE} contra una ruta y
     * devuelve las variables decodificadas.
     *
     * <p>Estático y package-private para poder probar la gramática
     * y la decodificación sin levantar el contexto de Spring ni
     * mockear el catálogo.
     */
    static Optional<Map<String, String>> matchTemplate(String template, String path) {
        String normalized = path.endsWith("/") && path.length() > 1
                ? path.substring(0, path.length() - 1)
                : path;
        PathPattern pattern = PARSER.parse(
                PathTemplateSyntax.toBracePattern(template));
        PathPattern.PathMatchInfo info =
                pattern.matchAndExtract(PathContainer.parsePath(normalized));
        return info == null
                ? Optional.empty()
                : Optional.of(info.getUriVariables());
    }

    public int size() {
        return tableRef.get().size();
    }

    public record Match(String uuid, Map<String, String> pathVars,
                        boolean cacheable, int cacheTtlSeconds) {}

    /**
     * V33 — immediate refresh trigger exposed via the
     * {@code POST /internal/invalidatePathRegistry} endpoint.
     * Called by sso-admin after a catalog mutation
     * (create/update/delete) so the path-registry picks up
     * the change without waiting for the periodic 60s tick.
     * Idempotent: a no-op when nothing changed.
     *
     * <p>Returns the new registry size so the caller can log
     * / verify the refresh actually loaded something.
     */
    public int invalidate() {
        refresh();
        return size();
    }
}
