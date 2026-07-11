package com.co.eurekatic.notificationservice.template;

import com.co.eurekatic.notificationservice.domain.NotificationMessage;
import com.co.eurekatic.notificationservice.domain.RenderedNotification;
import org.springframework.core.io.ClassPathResource;
import org.springframework.stereotype.Component;
import org.thymeleaf.TemplateEngine;
import org.thymeleaf.context.Context;
import org.thymeleaf.exceptions.TemplateInputException;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

/**
 * Renders a {@link NotificationMessage} into a
 * {@link RenderedNotification} by combining the channel-
 * specific template with the message's payload.
 *
 * <p>Resolution rules:
 * <ul>
 *   <li>EMAIL → {@code classpath:/templates/email/<templateId>.html}
 *       via Thymeleaf. The template is expected to include a
 *       {@code <title>} element whose text becomes the
 *       subject.</li>
 *   <li>SMS, PUSH → {@code classpath:/templates/<channel>/<templateId>.txt}
 *       read as a plain UTF-8 string and expanded with
 *       {@code {{var}}} substitution via {@link #interpolate}.
 *       SMS / push payloads are short by design, so
 *       Thymeleaf is overkill here.</li>
 * </ul>
 *
 * <p>Missing templates throw {@link TemplateNotFoundException}
 * — non-recoverable; the message goes straight to the DLQ.
 */
@Component
public class TemplateRenderer {

    private static final String EMAIL_TEMPLATE_PREFIX = "email/";
    private static final String SMS_TEMPLATE_PREFIX = "sms/";
    private static final String PUSH_TEMPLATE_PREFIX = "push/";

    private final TemplateEngine templateEngine;

    public TemplateRenderer(TemplateEngine templateEngine) {
        this.templateEngine = templateEngine;
    }

    public RenderedNotification render(NotificationMessage message) {
        return switch (message.channel()) {
            case EMAIL -> renderEmail(message);
            case SMS -> renderPlain(message, SMS_TEMPLATE_PREFIX);
            case PUSH -> renderPlain(message, PUSH_TEMPLATE_PREFIX);
        };
    }

    private RenderedNotification renderEmail(NotificationMessage message) {
        String templateName = EMAIL_TEMPLATE_PREFIX + message.templateId();
        String body;
        try {
            Context ctx = new Context();
            ctx.setVariables(message.payload());
            body = templateEngine.process(templateName, ctx);
        } catch (TemplateInputException ex) {
            throw new TemplateNotFoundException(message.templateId(), message.channel().name());
        }
        // Convention: the email template contains a <title> tag
        // whose text is the subject. Pulled out so the SMTP client
        // can set the headers without re-rendering the body.
        String subject = extractTitle(body, message.templateId());
        return new RenderedNotification(
                message.channel(),
                subject,
                body,
                null,
                message.recipient(),
                null,
                List.of()
        );
    }

    private RenderedNotification renderPlain(NotificationMessage message,
                                              String prefix) {
        String resourcePath = "templates/" + prefix + message.templateId() + ".txt";
        ClassPathResource resource = new ClassPathResource(resourcePath);
        if (!resource.exists()) {
            throw new TemplateNotFoundException(message.templateId(), message.channel().name());
        }
        String template;
        try {
            template = new String(resource.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException ioe) {
            throw new TemplateNotFoundException(message.templateId(), message.channel().name());
        }
        String body = interpolate(template, message.payload());
        return new RenderedNotification(
                message.channel(),
                null,
                null,
                body,
                message.recipient(),
                null,
                List.of()
        );
    }

    /**
     * Extracts the content of the first {@code <title>} tag in
     * the rendered HTML, falling back to a generic title if
     * the template author didn't include one.
     */
    private static String extractTitle(String html, String templateId) {
        int open = html.indexOf("<title>");
        int close = html.indexOf("</title>");
        if (open >= 0 && close > open) {
            return html.substring(open + "<title>".length(), close).trim();
        }
        return "Notification: " + templateId;
    }

    /**
     * Lightweight {@code {{var}}} substitution. Used by
     * {@link #renderPlain} and exposed for any caller that
     * needs the same expansion (e.g. console previews in
     * tests).
     */
    public static String interpolate(String template, Map<String, Object> vars) {
        String out = template;
        for (Map.Entry<String, Object> e : vars.entrySet()) {
            String token = "{{" + e.getKey() + "}}";
            out = out.replace(token, String.valueOf(e.getValue()));
        }
        return out;
    }
}