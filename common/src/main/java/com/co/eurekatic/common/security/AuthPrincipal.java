package com.co.eurekatic.common.security;

import java.util.Set;

/**
 * Lightweight, immutable view of an authenticated principal extracted from
 * a JWT. Returned by {@link JwtTokenService#parse(String)}; consumed by
 * Spring Security's authentication machinery in the api-gateway filter.
 *
 * @param email     the {@code sub} claim — the user's email, which is the
 *                  unique login identifier since the V12 migration
 *                  (the prior {@code username} column is gone).
 * @param userId    the {@code uid} claim — the numeric
 *                  {@code users.id_user} primary key. Embedded in the JWT
 *                  at issuance so every downstream service has it without
 *                  an extra DB lookup. May be {@code null} for legacy
 *                  tokens minted before the V29 rollout; callers that
 *                  need it (e.g. {@code query-service} injecting
 *                  {@code :caller_user_id}) must tolerate null and decide
 *                  whether to skip the parameter or surface 401.
 * @param roles     the {@code roles} claim (already de-prefixed; e.g. {@code "USER"})
 * @param tokenType "access" or "api"
 * @param familyId  the {@code fid} claim — the refresh-token family UUID
 *                  ({@code RefreshTokenStore.mint()} output), stable
 *                  across cada rotación de refresh. Embedded en el JWT
 *                  para que el ciclo de vida de la sesión viaje sin un
 *                  lookup extra a Redis. {@code null} para tokens minted
 *                  antes de V-audit-ctx-4 — los llamantes lo toleran y
 *                  caen al fallback "sesión desconocida" en auditoría.
 *                  En este sistema familyId ES la sesion_id (la fila de
 *                  {@code academico_test.tsesion_web} se indexa por él),
 *                  por eso un solo campo sirve para los dos nombres —
 *                  ver {@code docs/etiqueta-auditoria-cdc-analisis.md}
 *                  §V-audit-ctx-4.
 * @param establishment el claim {@code est} — nombre legible (no PK) del
 *                  establecimiento del que el usuario es rector/secretaria
 *                  (resuelto UNA vez al login, ver
 *                  {@code academico_test.fn_mi_establecimiento_para_auditoria} /
 *                  {@code pigse.fn_mi_establecimiento_para_auditoria}). Nombre
 *                  y no PK porque es justo lo que ya viaja sin índice dedicado
 *                  en {@code auditoria.audit_log.contexto} (columna JSON,
 *                  ver V66 {@code fn_audit_declarar}) — así el filtro de
 *                  auditoría por establecimiento del rector puede comparar
 *                  texto contra texto sin tocar el pipeline CDC. {@code null}
 *                  para quien no administra un único establecimiento (p. ej.
 *                  super-admin, o alguien con 2+ EE) — ausencia que el
 *                  filtro de auditoría interpreta como "sin scope, cae al
 *                  chequeo de rol".
 */
public record AuthPrincipal(
        String email,
        Long userId,
        Set<String> roles,
        String tokenType,
        String familyId,
        String establishment) {

    /** Legacy 3-arg constructor (pre-V29, sin uid). familyId/establishment null. */
    public AuthPrincipal(String email, Set<String> roles, String tokenType) {
        this(email, null, roles, tokenType, null, null);
    }

    /** V29 4-arg constructor (con uid). familyId/establishment null (pre-V-audit-ctx-4). */
    public AuthPrincipal(String email, Long userId, Set<String> roles, String tokenType) {
        this(email, userId, roles, tokenType, null, null);
    }

    /** Pre-establishment 5-arg constructor. establishment null. */
    public AuthPrincipal(String email, Long userId, Set<String> roles, String tokenType, String familyId) {
        this(email, userId, roles, tokenType, familyId, null);
    }

    public boolean hasRole(String role) {
        return roles != null && roles.contains(role);
    }
}
