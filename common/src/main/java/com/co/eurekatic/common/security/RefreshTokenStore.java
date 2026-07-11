package com.co.eurekatic.common.security;

import java.time.Instant;

/**
 * Backing store for rotating refresh tokens. The interface lives in
 * {@code common} so it can be injected into the auth-center filter
 * chain and the refresh/logout controllers without leaking Spring
 * Data Redis types into the shared module. The production impl
 * ({@code RedisRefreshTokenStore}) is in auth-center.
 *
 * <p>Design follows RFC 9700 §4.14 (OAuth 2.0 Security Best Current
 * Practice, Jan 2025):
 * <ul>
 *   <li>Refresh tokens are opaque, single-use, and rotated on every
 *       use ({@link #rotate}).</li>
 *   <li>Reuse of an already-rotated token triggers <em>family
 *       revocation</em> — every token in the same family is wiped,
 *       forcing the legitimate user to re-authenticate. This is the
 *       RFC 9700 §4.14.2 MUST.</li>
 *   <li>Raw tokens are never stored at rest. Callers pass the raw
 *       value to {@code mint} / {@code rotate} / {@code revokeToken}
 *       and the implementation is responsible for hashing before
 *       persistence.</li>
 * </ul>
 *
 * <p>The store is the source of truth for refresh-token validity;
 * the {@code users.refresh_token} DB column is dead code under this
 * contract and will be removed in a follow-up migration.
 */
public interface RefreshTokenStore {

    /**
     * Issue a new refresh token for {@code userId} inside the given
     * {@code familyId}. The family ID is opaque to the store — it
     * is supplied by the caller (one family per login) and is used
     * to bind rotated tokens together for reuse-detection.
     *
     * <p>{@code email} is carried alongside the token so the
     * controller can mint a new access token without a DB hit per
     * refresh. Email is the login identifier since the V12
     * migration (the prior {@code username} column is gone).
     *
     * @return a {@link RefreshTokenHandle} containing the raw token
     *         to set in the cookie + the opaque store-internal IDs
     * @throws RefreshUnavailableException if the backing store is
     *         unreachable; the caller MUST fail closed (503 on
     *         login, 401 on refresh — never fall back to a bypass)
     */
    RefreshTokenHandle mint(String email, String userId, String familyId);

    /**
     * Atomically validate + invalidate a refresh token and mint its
     * replacement in the same family.
     *
     * <p>Outcomes:
     * <ul>
     *   <li>{@link RefreshOutcome.Rotated} — the presented token was
     *       live; it has been deleted and a fresh handle is returned.</li>
     *   <li>{@link RefreshOutcome.ReuseDetected} — the token had
     *       already been rotated (or was never valid); the entire
     *       family has been wiped as a defensive measure.</li>
     *   <li>{@link RefreshOutcome.NotFound} — the token was not in
     *       the store at all (expired, manually deleted, never
     *       minted). Family is left untouched.</li>
     *   <li>{@link RefreshOutcome.Unavailable} — the backing store
     *       is down. Caller must return 401 and log ERROR.</li>
     * </ul>
     */
    RefreshOutcome rotate(String rawToken);

    /**
     * Return the metadata associated with a raw token without
     * consuming it. Used for diagnostics; not part of the refresh
     * path. Returns {@code null} if the token is not in the store.
     */
    RefreshTokenLookup peek(String rawToken);

    /**
     * Revoke every token belonging to the family. Called from
     * {@code /auth/logout} (via {@link #revokeToken}) and from
     * {@link RefreshOutcome#ReuseDetected} as a side effect of
     * {@link #rotate}.
     */
    void revokeFamily(String familyId);

    /**
     * Revoke the specific token AND its entire family. Safe to call
     * with an unknown token (no-op).
     */
    void revokeToken(String rawToken);

    /**
     * Configured TTL in seconds, exposed so callers can write
     * {@code Max-Age} on the cookie to match the store.
     */
    long ttlSeconds();

    /**
     * Newly-minted refresh token. The raw value goes into the
     * {@code sso_refresh} cookie; the hash is the opaque store
     * identifier and never leaves the store.
     */
    record RefreshTokenHandle(
            String rawToken,
            String tokenHash,
            String familyId,
            Instant issuedAt,
            long ttlSeconds) {
    }

    /**
     * Read-only view of a token's metadata, returned by
     * {@link #peek}.
     */
    record RefreshTokenLookup(
            String email,
            String userId,
            String familyId,
            Instant issuedAt) {
    }

    /**
     * Sealed result type for {@link #rotate}. Carries enough context
     * for the controller to log / respond without a second store
     * call.
     */
    sealed interface RefreshOutcome permits RefreshOutcome.Rotated, RefreshOutcome.ReuseDetected, RefreshOutcome.NotFound, RefreshOutcome.Unavailable {

        /** Successful rotation. The new handle has been minted in the same family. */
        record Rotated(RefreshTokenHandle next) implements RefreshOutcome {}

        /**
         * The presented token had already been consumed. The
         * implementation has wiped the entire family as a defensive
         * measure; the caller MUST return 401 and clear the cookie.
         */
        record ReuseDetected(String email, String familyId) implements RefreshOutcome {}

        /** The token was never valid (expired, evicted, never minted). */
        record NotFound() implements RefreshOutcome {}

        /** Backing store unreachable. Caller must fail closed. */
        record Unavailable() implements RefreshOutcome {}
    }
}