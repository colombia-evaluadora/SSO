package com.co.eurekatic.notificationservice.domain;

import jakarta.validation.constraints.NotBlank;

/**
 * Recipient of a notification. {@code address} is a
 * per-channel string (E.164 phone for SMS, email for
 * EMAIL, device token for PUSH). {@code userId} is the
 * internal SSO user identifier when known; nullable for
 * outbound messages to non-users.
 */
public record Recipient(
        String userId,
        @NotBlank String address
) {
}
