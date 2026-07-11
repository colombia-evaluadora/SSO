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
 */
public record RenderedNotification(
        Channel channel,
        String subject,
        String bodyHtml,
        String bodyText,
        Recipient recipient,
        String from,
        List<String> attachments
) {
}
