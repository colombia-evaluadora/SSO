package com.co.eurekatic.ssoadmin.dto;

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
        Long                        microserviceId
) {}
