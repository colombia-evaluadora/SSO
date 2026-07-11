package com.co.eurekatic.ssoadmin.dto;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

import java.util.List;

/**
 * Request body for {@code POST /createAccount}. The admin no
 * longer types a username OR a password — email is the unique
 * login identifier (so we drop the legacy {@code username}
 * field) and the user sets their own password by clicking the
 * activation link in the email. {@code POST /activateAccount}
 * is the only place where a password first enters the system;
 * it BCrypts it and stamps {@code enabled=true} /
 * {@code active=true}.
 *
 * <p>Mirrors the legacy {@code com.co.lowcode.sso.model.User}
 * DTO minus the password fields, with modern Jakarta Bean
 * Validation annotations.
 */
public record CreateAccountRequest(
        @NotBlank @Size(max = 200) String fullName,
        @NotBlank @Email @Size(max = 200) String email,
        /** Roles to grant. Empty list → no roles. */
        List<@NotBlank String> roleNames
) {}
