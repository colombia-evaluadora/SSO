package com.co.eurekatic.ssoadmin.dto;

import com.co.eurekatic.common.entity.ExecutionMode;
import com.co.eurekatic.common.query.ParamConstraint;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

import java.util.LinkedHashMap;
import java.util.Map;

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
        @Size(max = 10)             String httpMethod,
        /**
         * V49 — author-declared JDBC/PG type per caller-controlled
         * placeholder. Shape: {@code {"PARAM.NOMBRE":"TEXT", "BODY.IDS":"BIGINT[]", ...}}.
         * Strict at write time: every {@code :PARAM.*} / {@code :BODY.*}
         * in the SQL must appear as a key. {@code :CONTEXT.*} and
         * {@code :QUERY.{SIZE,OFFSET}} are system-bound and need no entry.
         *
         * <p>Nullable for back-compat: callers that don't send the
         * field default to an empty map, which {@code QueryAdminService}
         * then treats as "no types declared" — the strict check
         * fires and rejects the save if any placeholder is present.
         */
        Map<String, String>         paramTypes,
        /**
         * V81 — restricciones de formato opcionales por placeholder,
         * adicionales al tipo/obligatoriedad de {@code paramTypes}.
         * Cada key debe existir en {@code paramTypes}; sólo las
         * reglas numéricas aplican a tipos numéricos y sólo las de
         * texto a tipos de texto — ver
         * {@code QueryAdminService.validateParamConstraints}.
         *
         * <p>Nullable: un cliente que no manda el campo cae a mapa
         * vacío (sin restricciones adicionales).
         */
        Map<String, ParamConstraint> paramConstraints,
        /**
         * V110 — opt-in: {@code query-service} may cache this row's
         * {@code GET} result in Redis when {@code true}. Default
         * {@code false} — the field is a checkbox on the admin-ui
         * form, unchecked by default, matching pre-V110 behavior.
         */
        boolean                     cacheable,
        /**
         * V110 — staleness window in seconds when {@code cacheable}
         * is {@code true}. Validated positive by
         * {@code QueryAdminService}; ignored otherwise.
         */
        Integer                     cacheTtlSeconds
) {

    /** Back-compat constructor for callers that haven't migrated to V27/V28 yet. */
    public QueryRequest(Long id, String uuid, String query, String type,
                        boolean publicEnd, boolean captcha,
                        String detail, String action, String style,
                        Long microserviceId) {
        this(id, uuid, query, type, publicEnd, captcha,
             detail, action, style, microserviceId, null,
             ExecutionMode.SELECT, null, null, null, null, false, null);
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
             pathTemplate, executionMode, null, null, null, null, false, null);
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
             pathTemplate, executionMode, outParamNames, null, null, null, false, null);
    }

    /**
     * V33 back-compat (sin paramTypes). Conserva la forma de
     * 14 argumentos que los llamantes usaban antes de V49; el
     * mapa de tipos cae a vacío, que {@code QueryAdminService}
     * interpreta como "sin tipos declarados" y rechaza si el SQL
     * tiene placeholders caller-controlled.
     */
    public QueryRequest(Long id, String uuid, String query, String type,
                        boolean publicEnd, boolean captcha,
                        String detail, String action, String style,
                        Long microserviceId, String pathTemplate,
                        ExecutionMode executionMode, String outParamNames,
                        String httpMethod) {
        this(id, uuid, query, type, publicEnd, captcha,
             detail, action, style, microserviceId,
             pathTemplate, executionMode, outParamNames, httpMethod,
             null, null, false, null);
    }

    /**
     * V81/V110 back-compat (sin paramConstraints ni
     * cacheable/cacheTtlSeconds). Conserva la forma de 15
     * argumentos que los llamantes usaban antes de esos dos
     * campos; ambos caen a su default (mapa vacío / sin cachear).
     */
    public QueryRequest(Long id, String uuid, String query, String type,
                        boolean publicEnd, boolean captcha,
                        String detail, String action, String style,
                        Long microserviceId, String pathTemplate,
                        ExecutionMode executionMode, String outParamNames,
                        String httpMethod, Map<String, String> paramTypes) {
        this(id, uuid, query, type, publicEnd, captcha,
             detail, action, style, microserviceId,
             pathTemplate, executionMode, outParamNames, httpMethod,
             paramTypes, null, false, null);
    }

    /**
     * V110 back-compat (sin cacheable/cacheTtlSeconds). Conserva la
     * forma de 16 argumentos que los llamantes usaban entre V81 y
     * V110; ambos caen a su default (sin cachear).
     */
    public QueryRequest(Long id, String uuid, String query, String type,
                        boolean publicEnd, boolean captcha,
                        String detail, String action, String style,
                        Long microserviceId, String pathTemplate,
                        ExecutionMode executionMode, String outParamNames,
                        String httpMethod, Map<String, String> paramTypes,
                        Map<String, ParamConstraint> paramConstraints) {
        this(id, uuid, query, type, publicEnd, captcha,
             detail, action, style, microserviceId,
             pathTemplate, executionMode, outParamNames, httpMethod,
             paramTypes, paramConstraints, false, null);
    }

    /**
     * Constructor canónico. Acepta {@code paramTypes} null y lo
     * convierte en mapa vacío — la validación estricta vive en
     * {@code QueryAdminService.validateParamTypes}, no aquí.
     * {@code cacheTtlSeconds} null (sin valor enviado por el
     * cliente) cae al default que aplica
     * {@code QueryAdminService.copy} sobre la entidad.
     */
    public QueryRequest {
        paramTypes = paramTypes == null ? new LinkedHashMap<>() : paramTypes;
        paramConstraints = paramConstraints == null ? new LinkedHashMap<>() : paramConstraints;
    }
}
