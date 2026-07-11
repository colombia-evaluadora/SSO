package com.co.eurekatic.notificationservice.domain;

import com.fasterxml.jackson.annotation.JsonProperty;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;

import java.util.Map;
import java.util.UUID;

/**
 * Envelope received off RabbitMQ. Every field except
 * {@code recipient.userId} and {@code metadata.correlationId}
 * is required by the spec — a missing required field is a
 * non-recoverable error and goes to the DLQ without retry.
 *
 * <p>Modeled as a Java {@code record} so the Jackson
 * deserializer (in {@code RabbitTopologyConfig}) and the
 * Bean Validation annotations share a single source of
 * truth. The {@code @JsonProperty} on {@code notificationId}
 * mirrors the snake_case → camelCase mapping the rest of
 * the project's DTOs use.
 */
public record NotificationMessage(
        @NotNull
        @JsonProperty("notificationId")
        UUID notificationId,

        @NotNull
        Channel channel,

        @NotNull
        @Valid
        Recipient recipient,

        @NotBlank
        @JsonProperty("templateId")
        String templateId,

        @NotNull
        @NotEmpty
        Map<String, Object> payload,

        @NotNull
        @Valid
        Metadata metadata
) {
}
