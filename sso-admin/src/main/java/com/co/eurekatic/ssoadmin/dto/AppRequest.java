package com.co.eurekatic.ssoadmin.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * Request body for {@code POST /app/save} and
 * {@code PUT /app/update}. Mirrors the legacy
 * {@code SSO_V2.APP} insert/update shape: {@code name}
 * (unique, required) + {@code description} (optional).
 *
 * <p>Membership (users / roles / routes / microservices)
 * is managed through dedicated {@code /bind*} endpoints on
 * {@link com.co.eurekatic.ssoadmin.controller.AppController}
 * — not via this DTO — so creating an app stays a single
 * row insert and the binding tables don't get tangled with
 * the app's own identity on write.
 *
 * <p>{@code launchUrl} is what the post-login app launcher
 * opens for this app (relative {@code /admin/}-style for
 * this same SPA, absolute for an external app) — optional,
 * since an app can exist in the catalog before its launch
 * target is configured.
 */
public record AppRequest(
        Long id,
        @NotBlank @Size(max = 255) String name,
        @Size(max = 500) String description,
        @Size(max = 500) String launchUrl
) {}