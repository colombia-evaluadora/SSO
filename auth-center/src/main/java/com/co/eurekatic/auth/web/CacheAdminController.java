package com.co.eurekatic.auth.web;

import com.co.eurekatic.auth.security.SessionCacheProperties;
import com.co.eurekatic.auth.security.UserRolesCacheInvalidator;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Internal endpoint hit by sso-admin after any mutation that
 * changes a user's effective roles (direct role binding, group
 * membership, group's role binding). Drops the affected email
 * from the cache so the next login / refresh re-reads from the DB.
 *
 * <p>Authentication is a shared secret header
 * ({@code X-Session-Cache-Secret}, value
 * {@code sso.session.user-roles.invalidation-secret}). The endpoint
 * is reachable only from inside the trust boundary; in production
 * the docker-compose network is the gate. Missing header → 401,
 * wrong value → 403.
 *
 * <p>Mailformed emails are rejected with 400 rather than silently
 * being ignored — better than wasting the sso-admin admin's time
 * with a typo that "succeeded" but didn't actually invalidate.
 */
@RestController
@RequestMapping("/internal/cache")
public class CacheAdminController {

    private static final Logger log = LoggerFactory.getLogger(CacheAdminController.class);

    public static final String SECRET_HEADER = "X-Session-Cache-Secret";

    private final UserRolesCacheInvalidator invalidator;
    private final SessionCacheProperties props;

    public CacheAdminController(UserRolesCacheInvalidator invalidator,
                                SessionCacheProperties props) {
        this.invalidator = invalidator;
        this.props = props;
    }

    @PostMapping("/user-roles/{email}")
    public ResponseEntity<Void> invalidate(@PathVariable("email") String email,
                                          @RequestHeader(value = SECRET_HEADER, required = false) String secret) {
        if (secret == null) {
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).build();
        }
        if (props.invalidationSecret() == null || props.invalidationSecret().isBlank()
                || !constantTimeEquals(props.invalidationSecret(), secret)) {
            return ResponseEntity.status(HttpStatus.FORBIDDEN).build();
        }
        if (email == null || email.isBlank() || !email.contains("@")) {
            return ResponseEntity.badRequest().build();
        }
        invalidator.invalidate(email);
        log.info("User-roles cache invalidated email={}", email);
        return ResponseEntity.noContent().build();
    }

    /**
     * Length-aware comparison so an attacker can't time-probe the
     * secret character-by-character. Both branches iterate over
     * the configured secret's length.
     */
    private static boolean constantTimeEquals(String expected, String supplied) {
        byte[] a = expected.getBytes();
        byte[] b = supplied.getBytes();
        if (a.length != b.length) {
            // Still touch every byte of `a` to keep timing
            // independent of the supplied length.
            int diff = a.length ^ b.length;
            for (byte v : a) diff |= v;
            return false;
        }
        int diff = 0;
        for (int i = 0; i < a.length; i++) {
            diff |= a[i] ^ b[i];
        }
        return diff == 0;
    }
}