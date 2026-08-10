package com.co.eurekatic.ssoadmin.dto;

import com.co.eurekatic.common.entity.ExecutionMode;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * Request body for {@code POST /query/save} and
 * {@code PUT /query/update}. The {@code uuid} is the public
 * handle clients send to {@code query-service}; uniqueness on
 * it is enforced at the DB level and pre-checked in the
 * service layer for a friendlier 409.
 *
 * <p><b>{@code uuid} es opcional.</b> Si llega null o en blanco,
 * {@code QueryAdminService} lo genera ({@code UUID.randomUUID()})
 * en el create y conserva el existente en el update — nunca se
 * regenera sobre una fila viva, porque es el handle que los
 * consumidores ya tienen cableado. Se mantiene aceptando un valor
 * explícito para importaciones y filas legacy con uuid con
 * significado ({@code "reporte-ventas"}); el admin-ui no envía uno
 * al crear. El {@code @Size} sigue vigente: la columna es
 * VARCHAR(64) y un UUID canónico ocupa 36.
 *
 * <p>{@code detail}, {@code action}, and {@code style} are
 * passed through to the consumer as opaque JSON strings — the
 * admin UI is the only thing that knows their schema. The
 * catalog endpoint returns them verbatim, so whatever shape the
 * admin UI stores is what the low-code renderer sees.
 *
 * <p>{@code microserviceId} binds the query to a backing
 * {@code query-service-<instance>} container. Nullable: a
 * {@code null} value keeps the query "global" so any instance
 * with the right datasource may serve it (legacy behavior,
 * still useful for the canonical single-instance deployment).
 * When non-null the service layer enforces that the referenced
 * row is {@code kind=QUERY} — binding a {@code REST} row is
 * rejected with 422 because no container runs there.
 *
 * <p><b>V27</b> — {@code pathTemplate} exposes the query at
 * {@code MICROSERVICE.REQUEST_URI + pathTemplate}. Validated
 * by {@code QueryAdminService} (must start with "/" and be
 * unique within the microservice).
 *
 * <p><b>V28</b> — {@code executionMode} tells {@code query-service}
 * whether to run the row as a SELECT, a {@code CALL schema.proc()},
 * or a {@code SELECT * FROM schema.func()}. Defaults to SELECT so
 * pre-V28 callers keep working.
 */
public record QueryRequest(
        Long id,
        @Size(max = 64)             String uuid,
        @NotBlank                   String query,
        @Size(max = 64)             String type,
        boolean                     publicEnd,
        boolean                     captcha,
        String                      detail,
        String                      action,
        String                      style,
        Long                        microserviceId,
        @Size(max = 500)            String pathTemplate,
        ExecutionMode               executionMode,
        @Size(max = 500)            String outParamNames,
        /**
         * V33 — verbo HTTP: GET, POST o PUT. Null se trata como
         * POST, que es el comportamiento anterior a V33, para que
         * un cliente que no mande el campo siga funcionando igual.
         */
        @Size(max = 10)             String httpMethod
) {

    /** Back-compat constructor for callers that haven't migrated to V27/V28 yet. */
    public QueryRequest(Long id, String uuid, String query, String type,
                        boolean publicEnd, boolean captcha,
                        String detail, String action, String style,
                        Long microserviceId) {
        this(id, uuid, query, type, publicEnd, captcha,
             detail, action, style, microserviceId, null,
             ExecutionMode.SELECT, null, null);
    }

    /**
     * V27+V28 back-compat (no outParamNames). Preserves the
     * 11-arg shape callers used before V31.
     */
    public QueryRequest(Long id, String uuid, String query, String type,
                        boolean publicEnd, boolean captcha,
                        String detail, String action, String style,
                        Long microserviceId,
                        String pathTemplate, ExecutionMode executionMode) {
        this(id, uuid, query, type, publicEnd, captcha,
             detail, action, style, microserviceId,
             pathTemplate, executionMode, null, null);
    }

    /**
     * V31 back-compat (sin httpMethod). Conserva la forma de
     * 13 argumentos que los llamantes usaban antes de V33; el
     * verbo cae a POST, que es lo que hacían todas las rutas.
     */
    public QueryRequest(Long id, String uuid, String query, String type,
                        boolean publicEnd, boolean captcha,
                        String detail, String action, String style,
                        Long microserviceId, String pathTemplate,
                        ExecutionMode executionMode, String outParamNames) {
        this(id, uuid, query, type, publicEnd, captcha,
             detail, action, style, microserviceId,
             pathTemplate, executionMode, outParamNames, null);
    }
}
