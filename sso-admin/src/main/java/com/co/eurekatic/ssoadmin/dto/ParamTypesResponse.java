package com.co.eurekatic.ssoadmin.dto;

import java.util.List;
import java.util.Map;

/**
 * Response of {@code GET /query/param-types}. Exposes the curated PG/JDBC
 * type set ({@link com.co.eurekatic.common.query.ParamTypes#CURATED})
 * to the admin UI so it doesn't have to hardcode a copy that could drift.
 *
 * <p>{@code jdbcTypes} is the same name-to-{@link java.sql.Types} map
 * the runtime uses, useful if a future UI wants to show the JDBC type
 * alongside the friendly name. Today only {@code curated} is consumed.
 *
 * <p>V49-bis — {@code pgCastName} exposes the SQL cast target per type.
 * Para tipos built-in es el nombre PG ({@code integer}, {@code jsonb}, etc.);
 * para los DOMAIN types del schema {@code academico_test} viene con
 * schema-qualified name ({@code academico_test.bool_sn}). La UI lo usa
 * si quiere mostrar al autor qué cast se va a generar.
 *
 * <p>The set changes rarely, so the UI caches it aggressively
 * ({@code staleTime: Infinity}) and refreshes on deploy.
 *
 * <p>V62 — {@code requiredSuffix} is the literal ({@code "!"}) the UI
 * appends to a base type from {@code curated} to mark a parameter as
 * obligatorio (see {@link com.co.eurekatic.common.query.ParamTypes#parseDeclaration}).
 * Exposed instead of hardcoded on the frontend so both sides read the
 * convention from the same source.
 *
 * <p>V63 — {@code fileClassificationSeparator} is the literal
 * ({@code ":"}) the UI inserts between {@code FILE} and the
 * classification the author types, when the selected type is
 * {@code FILE} — see
 * {@link com.co.eurekatic.common.query.ParamTypes#FILE_CLASSIFICATION_SEPARATOR}.
 * Same reasoning as {@code requiredSuffix}: one source of truth for
 * the literal, not a copy hardcoded on each side.
 */
public record ParamTypesResponse(
        List<String> curated,
        Map<String, Integer> jdbcTypes,
        Map<String, String> pgCastName,
        String requiredSuffix,
        String fileClassificationSeparator
) { }