package com.co.eurekatic.ssoadmin.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * Shared request body for {@code POST /activateAccount} and
 * {@code POST /restorePassword}.
 *
 * <p>Both endpoints accept the same pair: a single-use token
 * (delivered in the activation or restore-password email) plus
 * the new password. Sharing one DTO keeps the validation rule
 * ({@code @Size(min = 6)} on {@code password}) in lockstep
 * across the two flows and avoids a copy-paste record.
 *
 * <p><strong>Security:</strong> this DTO exists because the
 * legacy GET-with-query-string shape leaked the password via
 * server access logs, reverse-proxy logs, browser history,
 * and the {@code Referer} header. POST + JSON body confines the
 * password to the request body, which those surfaces never log
 * by default. CSRF remains disabled at the
 * {@code SecurityConfig} layer because the {@code token} is
 * itself a 36-char UUID capability — an attacker would have to
 * already possess it (which means they already own the user's
 * email inbox) to trigger the flow.
 */
public record TokenPasswordRequest(
        @NotBlank String token,
        @NotBlank @Size(min = 6, max = 100) String password
) {}
