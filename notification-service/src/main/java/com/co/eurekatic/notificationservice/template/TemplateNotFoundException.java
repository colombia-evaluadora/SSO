package com.co.eurekatic.notificationservice.template;

/**
 * Thrown when no template file matches the requested
 * {@code templateId}. Treated as <em>non-recoverable</em>
 * by the consumer: messages with this failure are routed
 * straight to the DLQ (no retry), because retrying the
 * same template name will keep failing.
 */
public class TemplateNotFoundException extends RuntimeException {

    public TemplateNotFoundException(String templateId, String channel) {
        super("Template not found: " + templateId + " (channel=" + channel + ")");
    }
}