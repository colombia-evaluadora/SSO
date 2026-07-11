package com.co.eurekatic.auth.security;

import com.co.eurekatic.common.security.RefreshTokenStore;
import com.co.eurekatic.common.security.RefreshUnavailableException;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.data.redis.core.RedisOperations;
import org.springframework.data.redis.core.SessionCallback;
import org.springframework.data.redis.core.StringRedisTemplate;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Duration;
import java.time.Instant;
import java.util.HexFormat;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * Redis-backed implementation of {@link RefreshTokenStore}.
 *
 * <h2>Redis layout</h2>
 * <ul>
 *   <li>{@code <prefix>:hash:<sha256-hex>} — STRING of JSON
 *       {@code {"email":"...","userId":"...","familyId":"...","issuedAt":...}}.</li>
 *   <li>{@code <prefix>:family:<familyId>} — SET of hashes for every
 *       token minted in this family. Cleared atomically on reuse
 *       detection or on explicit logout.</li>
 * </ul>
 * <p>Both keys are written with the same TTL ({@code sso.refresh-token.ttl-seconds}).
 * The token hash is the canonical store-internal ID — the raw token
 * only ever exists on the wire (cookie + JSON response) and in the
 * user's browser.
 *
 * <h2>Concurrency</h2>
 * <p>{@link #rotate(String)} uses {@link SessionCallback} with MULTI/EXEC
 * so the read-then-delete is atomic from the caller's perspective: two
 * concurrent requests with the same cookie see exactly one
 * {@code Rotated} and one {@code ReuseDetected} (the second caller
 * reads the post-GETDEL key, sees {@code null}, and the family is
 * already wiped by the first caller's EXEC). RFC 9700 §4.14.2
 * prescribes this behaviour.
 */
public class RedisRefreshTokenStore implements RefreshTokenStore {

    private static final Logger log = LoggerFactory.getLogger(RedisRefreshTokenStore.class);

    private final StringRedisTemplate redis;
    private final ObjectMapper mapper;
    private final RefreshTokenProperties props;

    /**
     * Tombstone TTL: how long a "this hash has been seen" marker
     * lives after the live record is deleted. Set to the full
     * token TTL — a replay attempt at any point during the cookie's
     * declared lifetime still triggers reuse-detection. After this
     * window the replay falls through to NotFound, which is the
     * correct behaviour (the cookie is past its own Max-Age).
     */
    private static final long TOMBSTONE_TTL_SECONDS = 30L * 24 * 60 * 60;

    public RedisRefreshTokenStore(
            StringRedisTemplate redis,
            ObjectMapper mapper,
            RefreshTokenProperties props) {
        this.redis = redis;
        this.mapper = mapper;
        this.props = props;
    }

    /* ====================== mint ====================== */

    @Override
    public RefreshTokenHandle mint(String email, String userId, String familyId) {
        String raw = UUID.randomUUID().toString().replace("-", "");
        String hash = sha256Hex(raw);
        Instant issuedAt = Instant.now();
        long ttl = props.ttlSeconds();

        TokenRecord record = new TokenRecord(email, userId, familyId, issuedAt.getEpochSecond());
        String json;
        try {
            json = mapper.writeValueAsString(record);
        } catch (JsonProcessingException e) {
            // Should be impossible with a record of primitives.
            throw new RefreshUnavailableException("Failed to serialize refresh-token record", e);
        }

        String hashKey = hashKey(hash);
        String familyKey = familyKey(familyId);

        try {
            redis.execute(new SessionCallback<Object>() {
                @SuppressWarnings({"rawtypes", "unchecked"})
                @Override
                public Object execute(RedisOperations operations) throws DataAccessException {
                    operations.multi();
                    operations.opsForValue().set(hashKey, json);
                    operations.expire(hashKey, Duration.ofSeconds(ttl));
                    operations.opsForSet().add(familyKey, hash);
                    operations.expire(familyKey, Duration.ofSeconds(ttl));
                    return operations.exec();
                }
            });
        } catch (DataAccessException e) {
            throw new RefreshUnavailableException("Redis unavailable on mint", e);
        }

        log.debug("Refresh token minted family={} userId={}", shortFamily(familyId), userId);
        return new RefreshTokenHandle(raw, hash, familyId, issuedAt, ttl);
    }

    /* ====================== rotate ====================== */

    @Override
    public RefreshOutcome rotate(String rawToken) {
        if (rawToken == null || rawToken.isBlank()) {
            return new RefreshOutcome.NotFound();
        }
        String hash = sha256Hex(rawToken);
        String hashKey = hashKey(hash);

        // Step 1: read the existing record BEFORE the MULTI. If it's
        // missing we go straight to NotFound without touching Redis
        // further. If we read it inside MULTI/EXEC we'd race with the
        // GETDEL itself.
        String json;
        try {
            json = redis.opsForValue().get(hashKey);
        } catch (DataAccessException e) {
            log.error("Redis unavailable on rotate (read) hash_prefix={}", hashPrefix(hash), e);
            return new RefreshOutcome.Unavailable();
        }

        if (json == null) {
            // Token is not live. It could be (a) never minted / past
            // its TTL, or (b) a replay of an already-rotated cookie.
            // Distinguish via the tombstone key we write on every
            // successful rotation: if the tombstone is present this
            // is a reuse event, otherwise it's a genuine NotFound.
            String tombstone;
            try {
                tombstone = redis.opsForValue().get(replayKey(hash));
            } catch (DataAccessException e) {
                log.error("Redis unavailable on rotate (tombstone read) hash_prefix={}",
                        hashPrefix(hash), e);
                return new RefreshOutcome.Unavailable();
            }
            if (tombstone != null) {
                String[] parts = tombstone.split("\\|", 2);
                String email = parts.length > 0 ? parts[0] : "?";
                String familyId = parts.length > 1 ? parts[1] : "?";
                log.warn("Refresh-token reuse detected via tombstone — user={} family={}",
                        email, shortFamily(familyId));
                // Wipe the entire family — RFC 9700 §4.14.2 mandates
                // that any subsequent live token in the family be
                // invalidated as a side effect of detecting the
                // reuse. Without this, the legitimate user's newer
                // token (minted by the rotation that produced the
                // tombstone) would still be valid.
                try {
                    revokeFamily(familyId);
                } catch (RefreshUnavailableException ignored) {
                    // best-effort; we're already returning
                    // ReuseDetected which causes the controller to
                    // 401 + clear the cookie.
                }
                return new RefreshOutcome.ReuseDetected(email, familyId);
            }
            return new RefreshOutcome.NotFound();
        }

        TokenRecord existing;
        try {
            existing = mapper.readValue(json, TokenRecord.class);
        } catch (JsonProcessingException e) {
            log.error("Corrupt refresh-token record in Redis hash_prefix={}", hashPrefix(hash), e);
            // Treat as not-found rather than wiping the family on a
            // parse failure we can't reason about.
            return new RefreshOutcome.NotFound();
        }

        // Step 2: atomically GETDEL the hash + wipe the family +
        // write the tombstone for reuse-detection on replay.
        try {
            List<Object> results = redis.execute(new SessionCallback<List<Object>>() {
                @SuppressWarnings({"rawtypes", "unchecked"})
                @Override
                public List<Object> execute(RedisOperations operations) throws DataAccessException {
                    operations.multi();
                    operations.opsForValue().getAndDelete(hashKey);
                    Set<String> members = operations.opsForSet().members(familyKey(existing.familyId()));
                    if (members != null) {
                        for (String member : members) {
                            operations.opsForValue().getAndDelete(hashKey(member));
                        }
                    }
                    operations.opsForSet().remove(familyKey(existing.familyId()), hash);
                    operations.delete(familyKey(existing.familyId()));
                    // Tombstone: "email|familyId" with the
                    // configured TTL. A subsequent rotate() call
                    // against this same hash will see the tombstone,
                    // NOT find the live record, and return
                    // ReuseDetected.
                    operations.opsForValue().set(replayKey(hash),
                            existing.email() + "|" + existing.familyId(),
                            Duration.ofSeconds(TOMBSTONE_TTL_SECONDS));
                    return operations.exec();
                }
            });
            if (results == null) {
                // MULTI/EXEC was discarded (e.g. WATCH conflict). Treat
                // as a reuse event — the token was live enough that we
                // got past step 1, and the EXEC was aborted.
                return new RefreshOutcome.ReuseDetected(existing.email(), existing.familyId());
            }
        } catch (DataAccessException e) {
            log.error("Redis unavailable on rotate (write) family={}", shortFamily(existing.familyId()), e);
            return new RefreshOutcome.Unavailable();
        }

        // Step 3: mint the replacement in the SAME family.
        try {
            RefreshTokenHandle next = mint(existing.email(), existing.userId(), existing.familyId());
            log.info("Refresh token rotated family={} userId={}",
                    shortFamily(existing.familyId()), existing.userId());
            return new RefreshOutcome.Rotated(next);
        } catch (RefreshUnavailableException e) {
            return new RefreshOutcome.Unavailable();
        }
    }

    /* ====================== peek ====================== */

    @Override
    public RefreshTokenLookup peek(String rawToken) {
        if (rawToken == null || rawToken.isBlank()) {
            return null;
        }
        String hash = sha256Hex(rawToken);
        String hashKey = hashKey(hash);

        String json;
        try {
            json = redis.opsForValue().get(hashKey);
        } catch (DataAccessException e) {
            log.error("Redis unavailable on peek hash_prefix={}", hashPrefix(hash), e);
            throw new RefreshUnavailableException("Redis unavailable on peek", e);
        }
        if (json == null) {
            return null;
        }
        try {
            TokenRecord record = mapper.readValue(json, TokenRecord.class);
            return new RefreshTokenLookup(record.email(), record.userId(), record.familyId(),
                    Instant.ofEpochSecond(record.issuedAt()));
        } catch (JsonProcessingException e) {
            log.error("Corrupt refresh-token record on peek hash_prefix={}", hashPrefix(hash), e);
            return null;
        }
    }

    /* ====================== revoke ====================== */

    @Override
    public void revokeFamily(String familyId) {
        if (familyId == null || familyId.isBlank()) {
            return;
        }
        String fk = familyKey(familyId);
        try {
            Set<String> members = redis.opsForSet().members(fk);
            redis.execute(new SessionCallback<Object>() {
                @SuppressWarnings({"rawtypes", "unchecked"})
                @Override
                public Object execute(RedisOperations operations) throws DataAccessException {
                    operations.multi();
                    if (members != null) {
                        for (String member : members) {
                            operations.opsForValue().getAndDelete(hashKey(member));
                            // Clear any tombstone that points at this
                            // hash, so a logged-out token can't be
                            // confused with a replay after the family
                            // is wiped.
                            operations.delete(replayKey(member));
                        }
                    }
                    operations.delete(fk);
                    return operations.exec();
                }
            });
        } catch (DataAccessException e) {
            log.error("Redis unavailable on revokeFamily family={}", shortFamily(familyId), e);
            throw new RefreshUnavailableException("Redis unavailable on revokeFamily", e);
        }
    }

    @Override
    public void revokeToken(String rawToken) {
        if (rawToken == null || rawToken.isBlank()) {
            return;
        }
        String hash = sha256Hex(rawToken);
        String hashKey = hashKey(hash);
        String json;
        try {
            json = redis.opsForValue().get(hashKey);
        } catch (DataAccessException e) {
            log.error("Redis unavailable on revokeToken (read) hash_prefix={}", hashPrefix(hash), e);
            throw new RefreshUnavailableException("Redis unavailable on revokeToken", e);
        }
        if (json == null) {
            return; // already gone
        }
        String familyId;
        try {
            TokenRecord record = mapper.readValue(json, TokenRecord.class);
            familyId = record.familyId();
        } catch (JsonProcessingException e) {
            // Best-effort cleanup of the lone hash key.
            try {
                redis.delete(hashKey);
            } catch (DataAccessException ignored) {
                // swallow — we're already on a failure path
            }
            return;
        }
        revokeFamily(familyId);
    }

    /* ====================== introspection ====================== */

    @Override
    public long ttlSeconds() {
        return props.ttlSeconds();
    }

    /* ====================== helpers ====================== */

    private String hashKey(String hash) {
        return props.keyPrefix() + ":hash:" + hash;
    }

    private String familyKey(String familyId) {
        return props.keyPrefix() + ":family:" + familyId;
    }

    /**
     * Tombstone key: written on every successful rotation so a
     * subsequent rotate() call against the same (now-deleted) hash
     * can detect the replay. See {@link #rotate(String)}.
     */
    private String replayKey(String hash) {
        return props.keyPrefix() + ":replay:" + hash;
    }

    private static String sha256Hex(String input) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] digest = md.digest(input.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException e) {
            // SHA-256 is mandatory in every JDK since Java 7. Reaching
            // here means a broken JRE; better to fail loudly than to
            // silently weaken the hash.
            throw new IllegalStateException("SHA-256 not available", e);
        }
    }

    private static String shortFamily(String familyId) {
        return familyId == null ? "?" : familyId.substring(0, Math.min(8, familyId.length()));
    }

    private static String hashPrefix(String hash) {
        return hash == null ? "?" : hash.substring(0, Math.min(8, hash.length()));
    }

    /** JSON record stored at {@code <prefix>:hash:<sha256-hex>}. */
    public record TokenRecord(String email, String userId, String familyId, long issuedAt) {
    }
}