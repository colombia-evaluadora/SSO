package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.UserRepository;
import com.co.eurekatic.ssoadmin.exception.TokenExpiredException;
import com.co.eurekatic.ssoadmin.exception.TokenNotFoundException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.UUID;

/**
 * Generates and validates the activation and restore-password
 * tokens that link the email-link flow to the user record.
 *
 * <p>The token is a 36-char UUID written to either
 * {@code User.tokenActivation} (new account) or
 * {@code User.tokenRestore} (forgot password), paired with an
 * expiry timestamp (V13 migration) that mirrors the
 * {@code ttlMinutes} value already advertised in the
 * activation/restore emails ({@code UserAdminService}). A
 * token is invalidated either by clearing the column on
 * successful use, or by expiring — {@link #consumeActivationToken}
 * / {@link #consumeRestoreToken} check both.
 */
@Service
public class TokenService {

    /** Matches the "ttlMinutes": 60 sent in the activation email payload. */
    static final long ACTIVATION_TTL_MINUTES = 60;
    /** Matches the "ttlMinutes": 30 sent in the restore-password email payload. */
    static final long RESTORE_TTL_MINUTES = 30;

    private final UserRepository userRepository;

    public TokenService(UserRepository userRepository) {
        this.userRepository = userRepository;
    }

    /**
     * Issues a new activation token and persists it (with its
     * expiry) on the user's {@code tokenActivation} column. The
     * user is not saved elsewhere by this method — caller is
     * responsible for saving the user (e.g. on createAccount).
     *
     * @return the new token (36-char UUID)
     */
    public String issueActivationToken(User user) {
        String token = generate();
        user.setTokenActivation(token);
        user.setTokenActivationExpiresAt(Instant.now().plus(ACTIVATION_TTL_MINUTES, ChronoUnit.MINUTES));
        return token;
    }

    /**
     * Issues a new restore-password token and persists it (with
     * its expiry) on the user's {@code tokenRestore} column.
     * Caller is responsible for saving the user.
     */
    public String issueRestoreToken(User user) {
        String token = generate();
        user.setTokenRestore(token);
        user.setTokenRestoreExpiresAt(Instant.now().plus(RESTORE_TTL_MINUTES, ChronoUnit.MINUTES));
        return token;
    }

    /**
     * Looks up the user that holds the given activation token.
     * Clears the token column (and its expiry) on the returned
     * entity — caller is responsible for saving the user.
     *
     * @throws TokenNotFoundException if no user has this token
     * @throws TokenExpiredException  if the token is past its expiry
     */
    @Transactional
    public User consumeActivationToken(String token) {
        User user = userRepository.findByTokenActivation(token)
                .orElseThrow(TokenNotFoundException::new);
        if (isExpired(user.getTokenActivationExpiresAt())) {
            throw new TokenExpiredException();
        }
        user.setTokenActivation(null);
        user.setTokenActivationExpiresAt(null);
        return user;
    }

    /**
     * Same as {@link #consumeActivationToken} but for the
     * restore-password flow.
     */
    @Transactional
    public User consumeRestoreToken(String token) {
        User user = userRepository.findByTokenRestore(token)
                .orElseThrow(TokenNotFoundException::new);
        if (isExpired(user.getTokenRestoreExpiresAt())) {
            throw new TokenExpiredException();
        }
        user.setTokenRestore(null);
        user.setTokenRestoreExpiresAt(null);
        return user;
    }

    /** Treats a missing expiry (pre-V13 row, shouldn't happen post-migration) as expired — fail closed. */
    private static boolean isExpired(Instant expiresAt) {
        return expiresAt == null || expiresAt.isBefore(Instant.now());
    }

    private static String generate() {
        return UUID.randomUUID().toString();
    }
}
