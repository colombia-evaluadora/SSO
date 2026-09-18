package com.co.eurekatic.notificationservice.domain;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;

import java.time.Instant;

/**
 * Provenance metadata attached to every message. The
 * {@code source} field identifies the producing service
 * (e.g. {@code sso-admin}); {@code correlationId} is the
 * caller's trace identifier when present; {@code timestamp}
 * is when the producer published the message, parsed as
 * an {@link Instant} (Jackson + JavaTimeModule).
 *
 * <p>The spec marks {@code timestamp} as required; we model
 * it as {@code @NotNull Instant} so a missing field is
 * caught by the processor's bean-validation step (no
 * retry — straight to DLQ as a non-recoverable error).
 *
 * <p>{@code appName} is optional — most producers/flows don't know
 * which app triggered the notification (or it doesn't matter for
 * them). When present (e.g. {@code sso-admin}'s {@code
 * forgotPassword}, which already takes an {@code app} request
 * param), {@code EmailSender} uses it to pick the {@code
 * provider_config} row scoped to that app (see {@code
 * ProviderConfigRow.appName}) instead of just the global
 * priority/failover roster — so a password-reset for PIGSE sends
 * from PIGSE's verified ZeptoMail domain, not Colombia Evaluadora's.
 */
public record Metadata(
        @NotBlank String source,
        String correlationId,
        @NotNull Instant timestamp,
        String appName
) {
}
