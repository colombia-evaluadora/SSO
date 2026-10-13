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
import org.springframework.data.redis.core.script.DefaultRedisScript;
import org.springframework.data.redis.core.script.RedisScript;

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
 * <p>{@link #rotate(String)} runs a single Lua script (atomic in Redis):
 * GETDEL of the live hash, deletion of every sibling hash and the family
 * set, and the replay tombstone. Only the caller whose GETDEL returned
 * the record gets {@code Rotated}; a concurrent caller with the same
 * cookie gets nil, finds the tombstone and receives {@code ReuseDetected}
 * (which also wipes the family). RFC 9700 §4.14.2 prescribes this
 * behaviour.
 */
public class RedisRefreshTokenStore implements RefreshTokenStore {

    private static final Logger log = LoggerFactory.getLogger(RedisRefreshTokenStore.class);

    /**
     * Rotacion atomica. KEYS[1] = hash vivo; ARGV = prefijo, hash, TTL del
     * tombstone. Devuelve el JSON del registro (si este llamador lo borro) o
     * nil (no existia: lo decide el tombstone). Si el JSON no se puede
     * decodificar, devuelve el JSON sin tocar la familia (el llamador lo trata
     * como NotFound).
     */
    private static final RedisScript<String> ROTATE_SCRIPT = new DefaultRedisScript<>("""
            local json = redis.call('GETDEL', KEYS[1])
            if not json then return nil end
            local ok, rec = pcall(cjson.decode, json)
            if not ok or type(rec) ~= 'table' or not rec.familyId then return json end
            local famKey = ARGV[1] .. ':family:' .. rec.familyId
            local members = redis.call('SMEMBERS', famKey)
            for _, m in ipairs(members) do
                redis.call('DEL', ARGV[1] .. ':hash:' .. m)
            end
            redis.call('DEL', famKey)
            redis.call('SET', ARGV[1] .. ':replay:' .. ARGV[2],
                       (rec.email or '?') .. '|' .. rec.familyId, 'EX', ARGV[3])
            return json
            """, String.class);

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

        // Step 1: un unico script Lua (atomico en Redis) hace GETDEL del
        // hash, borra los hermanos de la familia y escribe el tombstone.
        // Solo el llamador que de verdad borro el hash recibe el JSON; un
        // segundo llamador concurrente recibe nil y cae al tombstone.
        String json;
        try {
            json = redis.execute(ROTATE_SCRIPT, List.of(hashKey),
                    props.keyPrefix(), hash, String.valueOf(TOMBSTONE_TTL_SECONDS));
        } catch (DataAccessException e) {
            log.error("Redis unavailable on rotate hash_prefix={}", hashPrefix(hash), e);
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
            // El hash ya fue borrado por el script; sin familia legible
            // no se puede razonar mas: not-found, no se revoca a ciegas.
            return new RefreshOutcome.NotFound();
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