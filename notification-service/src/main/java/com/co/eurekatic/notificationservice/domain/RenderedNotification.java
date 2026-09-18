package com.co.eurekatic.notificationservice.domain;

import java.util.List;

/**
 * A notification after the template has been rendered —
 * the artefact that flows from {@code TemplateRenderer}
 * into a channel-specific {@code NotificationSender} and
 * then through the concrete {@code ChannelProvider}s.
 *
 * <p>For email, {@code subject} is non-null and {@code bodyHtml}
 * carries the Thymeleaf-rendered HTML. For SMS / push, both
 * are null and {@code bodyText} carries the placeholder-expanded
 * plaintext. {@code attachments} is reserved for future use
 * (empty for now).
 *
 * <p>{@code appName} carries {@code NotificationMessage.metadata()
 * .appName()} straight through — {@code null} when the producer
 * didn't set one. {@code EmailSender} reads it to pick the
 * app-scoped {@code provider_config} row (see {@code
 * ProviderConfigRow.appName}); SMS/PUSH senders ignore it today.
 */
public record RenderedNotification(
        Channel channel,
        String subject,
        String bodyHtml,
        String bodyText,
        Recipient recipient,
        String from,
        List<String> attachments,
        String appName
) {
}
