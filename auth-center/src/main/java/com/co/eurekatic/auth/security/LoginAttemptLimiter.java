package com.co.eurekatic.auth.security;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;

import java.time.Duration;
import java.util.List;
import java.util.Locale;

/**
 * Bloqueo de {@code POST /login} por intentos fallidos (QA-30): tras
 * {@code maxAttempts} credenciales inválidas para un mismo correo, ese
 * correo queda bloqueado {@code lockDuration} aunque luego mande la
 * contraseña correcta.
 *
 * <p>El contador vive en Redis para que lo compartan todas las réplicas.
 * Si Redis no responde se deja pasar (fail-open): un fallo de la caché no
 * debe tumbar el login de todo el mundo, y el semáforo de
 * {@link JsonLoginFilter} sigue acotando el ritmo de hashes.
 */
public class LoginAttemptLimiter {

    private static final Logger log = LoggerFactory.getLogger(LoginAttemptLimiter.class);

    public static final int DEFAULT_MAX_ATTEMPTS = 10;
    public static final Duration DEFAULT_LOCK_DURATION = Duration.ofMinutes(30);

    private final StringRedisTemplate redis;
    private final int maxAttempts;
    private final Duration lockDuration;
    private final String keyPrefix;

    public LoginAttemptLimiter(StringRedisTemplate redis, int maxAttempts,
                               Duration lockDuration, String keyPrefix) {
        this.redis = redis;
        this.maxAttempts = maxAttempts > 0 ? maxAttempts : DEFAULT_MAX_ATTEMPTS;
        this.lockDuration = lockDuration != null && !lockDuration.isNegative() && !lockDuration.isZero()
                ? lockDuration : DEFAULT_LOCK_DURATION;
        this.keyPrefix = keyPrefix == null || keyPrefix.isBlank() ? "sso:login" : keyPrefix;
    }

    /** Segundos que le quedan al bloqueo de ese correo; 0 si no está bloqueado. */
    public long secondsLocked(String email) {
        try {
            Long ttl = redis.getExpire(lockKey(email));
            return ttl != null && ttl > 0 ? ttl : 0;
        } catch (RuntimeException e) {
            log.warn("Redis no disponible al consultar el bloqueo de login", e);
            return 0;
        }
    }

    /**
     * Cuenta un intento fallido. Devuelve los segundos de bloqueo si con
     * este intento se llegó al tope, 0 si todavía le quedan intentos.
     */
    public long recordFailure(String email) {
        try {
            String failKey = failKey(email);
            Long count = redis.opsForValue().increment(failKey);
            if (count != null && count == 1) {
                // La ventana de conteo dura lo mismo que el bloqueo.
                redis.expire(failKey, lockDuration);
            }
            if (count != null && count >= maxAttempts) {
                redis.opsForValue().set(lockKey(email), "1", lockDuration);
                redis.delete(failKey);
                return lockDuration.toSeconds();
            }
            return 0;
        } catch (RuntimeException e) {
            log.warn("Redis no disponible al registrar un login fallido", e);
            return 0;
        }
    }

    /** Login correcto: el contador vuelve a cero. */
    public void reset(String email) {
        try {
            redis.delete(List.of(failKey(email), lockKey(email)));
        } catch (RuntimeException e) {
            log.warn("Redis no disponible al reiniciar el contador de login", e);
        }
    }

    /** "30 minutos", "1 minuto", "45 segundos": el texto del 429. */
    static String humanize(long seconds) {
        if (seconds < 60) {
            return seconds + (seconds == 1 ? " segundo" : " segundos");
        }
        long minutes = (seconds + 59) / 60;
        return minutes + (minutes == 1 ? " minuto" : " minutos");
    }

    private String failKey(String email) {
        return keyPrefix + ":failures:" + normalize(email);
    }

    private String lockKey(String email) {
        return keyPrefix + ":locked:" + normalize(email);
    }

    private static String normalize(String email) {
        return email == null ? "" : email.trim().toLowerCase(Locale.ROOT);
    }
}
