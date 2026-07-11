package com.co.eurekatic.notificationservice.service;

import com.co.eurekatic.notificationservice.domain.Channel;
import com.co.eurekatic.notificationservice.domain.NotificationLog;
import com.co.eurekatic.notificationservice.domain.NotificationMessage;
import com.co.eurekatic.notificationservice.domain.NotificationStatus;
import com.co.eurekatic.notificationservice.domain.RenderedNotification;
import com.co.eurekatic.notificationservice.provider.ProviderException;
import com.co.eurekatic.notificationservice.repository.NotificationLogRepository;
import com.co.eurekatic.notificationservice.sender.NotificationSender;
import com.co.eurekatic.notificationservice.sender.NotificationSenderRegistry;
import com.co.eurekatic.notificationservice.template.TemplateNotFoundException;
import com.co.eurekatic.notificationservice.template.TemplateRenderer;
import jakarta.validation.ConstraintViolation;
import jakarta.validation.Validator;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.AmqpRejectAndDontRequeueException;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.Set;

/**
 * Five-step pipeline executed per inbound message:
 *
 * <ol>
 *   <li><b>Validate</b> with bean-validation. Invalid →
 *       {@link AmqpRejectAndDontRequeueException} (DLQ, no retry).</li>
 *   <li><b>Insert log row</b> with status {@code PENDING}.
 *       The {@code notification_id} UNIQUE constraint catches
 *       duplicates — a {@link DataIntegrityViolationException}
 *       marks the existing row as {@code DUPLICATE} and ACKs
 *       the message.</li>
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
    private final NotificationLogRepository logRepository;
    private final TemplateRenderer renderer;
    private final NotificationSenderRegistry senders;

    public NotificationProcessor(Validator validator,
                                 NotificationLogRepository logRepository,
                                 TemplateRenderer renderer,
                                 NotificationSenderRegistry senders) {
        this.validator = validator;
        this.logRepository = logRepository;
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
        NotificationLog row = persistOrMarkDuplicate(message);
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
            markFailed(row, tnfe.getMessage());
            throw new AmqpRejectAndDontRequeueException(tnfe.getMessage(), tnfe);
        }

        // ---- 4. send ------------------------------------------------------
        String providerUsed;
        try {
            NotificationSender sender = senders.forChannel(channel);
            providerUsed = sender.send(rendered);
        } catch (ProviderException pe) {
            markFailed(row, pe.getMessage());
            throw pe; // recoverable → retry → DLQ via default-requeue-rejected: false
        } catch (RuntimeException ex) {
            markFailed(row, ex.toString());
            // Non-recoverable programmer error: don't retry.
            throw new AmqpRejectAndDontRequeueException("Non-recoverable send error", ex);
        }

        // ---- 5. update log -----------------------------------------------
        markSent(row, providerUsed);
    }

    @Transactional
    protected NotificationLog persistOrMarkDuplicate(NotificationMessage message) {
        try {
            return logRepository.saveAndFlush(new NotificationLog(
                    message.notificationId(),
                    message.channel(),
                    message.recipient().userId(),
                    message.templateId(),
                    NotificationStatus.PENDING
            ));
        } catch (DataIntegrityViolationException dive) {
            // Duplicate notificationId — the unique index on
            // notification_log.notification_id has already
            // won. Mark the existing row DUPLICATE so operators
            // can spot replays and ACK the new message.
            logRepository.findByNotificationId(message.notificationId())
                    .ifPresent(existing -> {
                        existing.markDuplicate();
                        logRepository.save(existing);
                    });
            return null;
        }
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    protected void markSent(NotificationLog row, String provider) {
        row.markSent(provider);
        logRepository.save(row);
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    protected void markFailed(NotificationLog row, String errorMessage) {
        row.markFailed("auto", errorMessage);
        logRepository.save(row);
    }
}