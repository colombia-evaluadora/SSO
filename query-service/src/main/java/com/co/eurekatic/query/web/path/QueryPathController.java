package com.co.eurekatic.query.web.path;

import com.co.eurekatic.common.query.ParamNamespace;
import com.co.eurekatic.query.read.QueryService;
import com.co.eurekatic.query.routing.QueryPathRegistry;
import com.co.eurekatic.query.web.QueryRequest;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * V27 — path-based query dispatcher.
 *
 * <p>The api-gateway strips the per-microservice
 * {@code REQUEST_URI} prefix (e.g. {@code /api/eval-col})
 * before forwarding, so requests arrive here as
 * {@code POST /<pathTemplate>}. Examples:
 * <ul>
 *   <li>{@code POST /api/eval-col/establecimiento/42}
 *       → forward → {@code POST /establecimiento/42}</li>
 *   <li>{@code POST /api/eval-col/users?active=true}
 *       → forward → {@code POST /users?active=true}</li>
 * </ul>
 *
 * <p>This controller catches any {@code POST /<anything>}
 * (other than the reserved legacy paths {@code /query},
 * {@code /service}, {@code /serviceFit},
 * {@code /public/service}, {@code /write}) and resolves
 * the request URI against {@link QueryPathRegistry}'s
 * {@code Map<pathTemplate, uuid>}. A 404 is returned when
 * no template matches — that path simply doesn't exist in
 * the catalog.
 *
 * <p><b>Cada parámetro lleva el prefijo de su origen</b>, de
 * modo que la SQL dice de dónde sale cada valor y los orígenes
 * no pueden pisarse entre sí:
 * <ul>
 *   <li>{@code :PARAM.X} — variables de la plantilla, así que
 *       {@code /establecimiento/:NOMBRE} bindea
 *       {@code :PARAM.NOMBRE}</li>
 *   <li>{@code :QUERY.X} — query string</li>
 *   <li>{@code :BODY.X.Y} — cuerpo JSON, aplanado con puntos:
 *       {@code {"filtros":{"zona":1}}} → {@code :BODY.FILTROS.ZONA}</li>
 *   <li>{@code :CONTEXT.X} — del JWT verificado</li>
 * </ul>
 * Ver {@link com.co.eurekatic.common.query.ParamNamespace}.
 *
 * <p><b>El contexto del llamante</b> (userId, email, roles) lo
 * inyecta {@link QueryService#execute} desde el
 * SecurityContextHolder, no desde la petición: es la única
 * familia de parámetros que el cliente no puede fabricar.
 */
@RestController
public class QueryPathController {

    private final QueryService service;
    private final QueryPathRegistry registry;

    public QueryPathController(QueryService service, QueryPathRegistry registry) {
        this.service = service;
        this.registry = registry;
    }

    /**
     * Catch-all POST handler. Spring's path matching picks
     * the more specific {@code /query}, {@code /service},
     * etc. mappings first; this one only fires for paths
     * the legacy controllers don't claim.
     */
    @GetMapping("/**")
    public Map<String, Object> dispatchGet(
            jakarta.servlet.http.HttpServletRequest request,
            @RequestParam Map<String, String> queryParams) {
        // Un GET no lleva cuerpo, así que no aporta :BODY.*. Que no
        // exista el parámetro aquí es deliberado: si alguien manda
        // un cuerpo en un GET, se ignora en vez de colarse como
        // binds que la validación al guardar ya prohibió.
        return dispatch(request, "GET", queryParams, null);
    }

    @PostMapping("/**")
    public Map<String, Object> dispatchPost(
            jakarta.servlet.http.HttpServletRequest request,
            @RequestParam Map<String, String> queryParams,
            @RequestBody(required = false) Map<String, Object> body) {
        return dispatch(request, "POST", queryParams, body);
    }

    @PutMapping("/**")
    public Map<String, Object> dispatchPut(
            jakarta.servlet.http.HttpServletRequest request,
            @RequestParam Map<String, String> queryParams,
            @RequestBody(required = false) Map<String, Object> body) {
        return dispatch(request, "PUT", queryParams, body);
    }

    /**
     * V50 — PATCH method. Idempotent semantics with partial body
     * (RFC 5789). Like PUT, it carries a body and matches the
     * same validation rules — PATCH on a DML row is allowed.
     * Registered after PUT so Spring's handler mapping resolves
     * the more specific path templates first.
     */
    @PatchMapping("/**")
    public Map<String, Object> dispatchPatch(
            jakarta.servlet.http.HttpServletRequest request,
            @RequestParam Map<String, String> queryParams,
            @RequestBody(required = false) Map<String, Object> body) {
        return dispatch(request, "PATCH", queryParams, body);
    }

    private Map<String, Object> dispatch(
            jakarta.servlet.http.HttpServletRequest request,
            String method,
            Map<String, String> queryParams,
            Map<String, Object> body) {

        String rawPath = (String) request.getAttribute(
                org.springframework.web.servlet.HandlerMapping.PATH_WITHIN_HANDLER_MAPPING_ATTRIBUTE);
        // Spring sometimes includes a trailing slash or an empty
        // path for the bare "/" mapping; normalize. Assigned once
        // into a final local because the orElseThrow lambda below
        // captures it, and a captured local must be effectively
        // final — reassigning `fullPath` in place would not compile.
        final String fullPath = (rawPath == null || rawPath.isEmpty()) ? "/" : rawPath;

        var match = registry.match(method, fullPath).orElseThrow(() -> {
            // 405 y no 404 cuando la ruta existe con otro verbo: la
            // URL está bien, lo que no se admite es el método. Un
            // 404 mandaría a quien depura a revisar la ruta, que es
            // justo donde no está el problema.
            if (registry.pathExistsWithAnotherMethod(method, fullPath)) {
                return new ResponseStatusException(HttpStatus.METHOD_NOT_ALLOWED,
                        "La ruta " + fullPath + " existe pero no admite "
                        + method);
            }
            return new ResponseStatusException(HttpStatus.NOT_FOUND,
                    "No query registered for path: " + fullPath);
        });

        Map<String, Object> params =
                buildParams(match.pathVars(), queryParams, body);

        QueryRequest qr = new QueryRequest(
                match.uuid(),
                params,
                /* limit  */ null,
                /* offset */ null);
        // publicOk=false: path-based queries are not
        // anonymous endpoints. A procedure author who
        // wants anonymous access should set publicEnd=true
        // AND mark the query without a role binding — same
        // gate as /query, just with a different URL.
        //
        // V31 — path-dispatch always uses the envelope
        // shape ({rows, outParams}) so callers can rely
        // on the same JSON shape regardless of mode.
        return com.co.eurekatic.query.web.query.QueryResultEnvelope
                .withOutParams(service.execute(qr, false));
    }

    /**
     * Arma el mapa de binds prefijando cada valor con su origen.
     *
     * <p>Los tres orígenes que controla el llamante viven en
     * namespaces separados, así que ya no pueden pisarse. Antes un
     * {@code ?nombre=} machacaba silenciosamente a la variable de
     * ruta {@code {nombre}} porque ambos escribían la misma clave,
     * y por tanto una ruta declarada podía secuestrarse desde el
     * query string.
     *
     * <p>{@code CONTEXT.*} lo añade {@code QueryService} desde el
     * JWT — deliberadamente fuera de aquí, porque nada que llegue
     * en la petición debe poder inventárselo.
     *
     * <p>Package-private y estático para poder probar la mezcla sin
     * montar MockMvc.
     */
    static Map<String, Object> buildParams(Map<String, String> pathVars,
                                           Map<String, String> queryParams,
                                           Map<String, Object> body) {
        Map<String, Object> params = new LinkedHashMap<>();
        // Las variables de ruta ya vienen validadas en MAYÚSCULA
        // ASCII desde el catálogo, así que se prefijan sin volver a
        // normalizar.
        if (pathVars != null) {
            for (Map.Entry<String, String> e : pathVars.entrySet()) {
                params.put(ParamNamespace.PARAM + "." + e.getKey(), e.getValue());
            }
        }
        ParamNamespace.putAll(params, ParamNamespace.QUERY, queryParams);
        if (body != null) {
            params.putAll(ParamNamespace.flatten(body, ParamNamespace.BODY));
        }
        return params;
    }
}
