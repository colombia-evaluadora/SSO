package com.co.eurekatic.common.dto;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

import java.util.Set;

/**
 * Authentication-related DTOs. Java records; immutable, terse, and serializable
 * to JSON by Jackson out of the box.
 *
 * <p>Bean-validation annotations ({@code @NotBlank}, {@code @Size}, etc.) on
 * records are picked up by Spring controllers when {@code @Valid} is used.
 */
public final class AuthDtos {

    private AuthDtos() {
        // utility class, no instances
    }

    /**
     * Login request body. The login identifier is now email (the
     * {@code username} column is gone since the V12 migration).
     */
    public record LoginRequest(
            @NotBlank @Email @Size(max = 200) String email,
            @NotBlank @Size(min = 1, max = 200) String password) {
    }

    /**
     * Successful authentication response. {@code token} is a compact JWS;
     * {@code expiresIn} is the lifetime in seconds.
     */
    public record TokenResponse(
            String token,
            String refreshToken,
            long expiresIn) {
    }

    /**
     * Lightweight public projection of the authenticated user. Never includes
     * the password hash. {@code roles} is the set of role names (not
     * "ROLE_USER"-prefixed). The {@code username} slot was removed in
     * the V12 migration: email IS the unique login identifier, so the
     * duplicate field served no purpose.
     */
    public record UserSummary(
            Long id,
            String email,
            String fullName,
            boolean enabled,
            boolean ldap,
            Set<String> roles) {
    }

    /**
     * Account creation request. Carries the minimum to create a pending
     * account; the actual password is set during activation. The
     * {@code username} slot was removed in the V12 migration — the
     * login identifier is now {@link #email}.
     */
    public record CreateAccountRequest(
            @NotBlank @Email @Size(max = 200) String email,
            @Size(max = 200) String fullName) {
    }

    /**
     * One entry of {@code GET /myApps} — the apps the caller's
     * roles have a {@code role_app} binding to. {@code launchUrl}
     * is null if an admin hasn't configured one yet for that app.
     */
    public record AppSummary(
            Long id,
            String name,
            String description,
            String launchUrl) {
    }
}
