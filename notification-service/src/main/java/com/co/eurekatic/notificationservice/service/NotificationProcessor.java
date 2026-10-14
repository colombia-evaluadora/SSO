package com.co.eurekatic.notificationservice.service;

import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.domain.NotificationLog;
import com.co.eurekatic.notificationservice.domain.NotificationMessage;
import com.co.eurekatic.notificationservice.domain.RenderedNotification;
import com.co.eurekatic.notificationservice.provider.ProviderException;
import com.co.eurekatic.notificationservice.sender.NotificationSender;
import com.co.eurekatic.notificationservice.sender.NotificationSenderRegistry;
import com.co.eurekatic.notificationservice.template.TemplateNotFoundException;
import com.co.eurekatic.notificationservice.template.TemplateRenderer;
import jakarta.validation.ConstraintViolation;
import jakarta.validation.Validator;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.AmqpRejectAndDontRequeueException;
import org.springframework.stereotype.Service;

import java.util.Set;

/**
 * Five-step pipeline executed per inbound message:
 *
 * <ol>
 *   <li><b>Validate</b> with bean-validation. Invalid →
 *       {@link AmqpRejectAndDontRequeueException} (DLQ, no retry).</li>
 *   <li><b>Insert log row</b> with status {@code PENDING}.
 *       The {@code notification_id} UNIQUE constraint catches
 *       duplicates: a row already {@code SENT} is marked
 *       {@code DUPLICATE} and the message ACKed; a row left
 *       {@code PENDING}/{@code FAILED} by a previous attempt is a
 *       legitimate retry and is reused.</li>
 *   <li><b>Render</b> the template. {@link TemplateNotFoundException}
 *       is non-recoverable → DLQ.</li>
 *   <li><b>Send</b> via the channel's {@link NotificationSender}.
 *       {@link ProviderException} is recoverable → bubble up so
 *       Spring AMQP retries; non-{@code ProviderException} runs
 *       are treated as bugs and go straight to the DLQ.</li>
 *   <li><b>Update</b> the log to {@code SENT} (with provider
 *       name) or {@code FAILED} (with the last error).</li>
 * </ol>
 *
 * <p>The processor itself does not touch Spring AMQP's retry
 * chain — that's the consumer's concern. It just throws the
 * right exception type so the framework picks the right
 * disposition.
 */
@Service
public class NotificationProcessor {

    private static final Logger log = LoggerFactory.getLogger(NotificationProcessor.class);

    private final Validator validator;
    private final NotificationLogWriter logWriter;
    private final TemplateRenderer renderer;
    private final NotificationSenderRegistry senders;

    public NotificationProcessor(Validator validator,
                                 NotificationLogWriter logWriter,
                                 TemplateRenderer renderer,
                                 NotificationSenderRegistry senders) {
        this.validator = validator;
        this.logWriter = logWriter;
        this.renderer = renderer;
        this.senders = senders;
    }

    /**
     * Entry point used by the consumer. Returns normally when
     * the message should be ACKed; throws
     * {@link AmqpRejectAndDontRequeueException} when the
     * message should land in the DLQ without retry; lets any
     * other exception bubble up so Spring AMQP's retry chain
     * kicks in.
     */
    public void process(NotificationMessage message, Channel channel) {
        // ---- 1. validate --------------------------------------------------
        Set<ConstraintViolation<NotificationMessage>> violations = validator.validate(message);
        if (!violations.isEmpty()) {
            String summary = violations.stream()
                    .map(v -> v.getPropertyPath() + " " + v.getMessage())
                    .reduce((a, b) -> a + "; " + b)
                    .orElse("invalid");
            log.warn("Rejecting message {}: {}", message.notificationId(), summary);
            throw new AmqpRejectAndDontRequeueException("Invalid notification: " + summary);
        }

        // ---- 2. idempotent insert -----------------------------------------
        NotificationLog row = logWriter.acquire(message);
        if (row == null) {
            log.info("Duplicate notification {} (channel={}), skipping",
                    message.notificationId(), channel);
            return;
        }

        // ---- 3. render ----------------------------------------------------
        RenderedNotification rendered;
        try {
            rendered = renderer.render(message);
        } catch (TemplateNotFoundException tnfe) {
            logWriter.markFailed(row, tnfe.getMessage());
            throw new AmqpRejectAndDontRequeueException(tnfe.getMessage(), tnfe);
        }

        // ---- 4. send ------------------------------------------------------
        String providerUsed;
        try {
            NotificationSender sender = senders.forChannel(channel);
            providerUsed = sender.send(rendered);
        } catch (ProviderException pe) {
            logWriter.markFailed(row, pe.getMessage());
            throw pe; // recoverable → retry → DLQ via default-requeue-rejected: false
        } catch (RuntimeException ex) {
            logWriter.markFailed(row, ex.toString());
            // Non-recoverable programmer error: don't retry.
            throw new AmqpRejectAndDontRequeueException("Non-recoverable send error", ex);
        }

        // ---- 5. update log -----------------------------------------------
        logWriter.markSent(row, providerUsed);
    }
}
