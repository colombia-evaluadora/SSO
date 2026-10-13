package com.co.eurekatic.notificationservice.service;

import com.co.eurekatic.notificationservice.domain.NotificationLog;
import com.co.eurekatic.notificationservice.domain.NotificationMessage;
import com.co.eurekatic.notificationservice.domain.NotificationStatus;
import com.co.eurekatic.notificationservice.repository.NotificationLogRepository;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.Optional;

/**
 * Persistence of the notification log, in its own bean so that
 * {@code @Transactional} is applied through the Spring proxy
 * (self-invocation from {@link NotificationProcessor} would skip it).
 */
@Service
public class NotificationLogWriter {

    private final NotificationLogRepository logRepository;

    public NotificationLogWriter(NotificationLogRepository logRepository) {
        this.logRepository = logRepository;
    }

    /**
     * Returns the row to work on, or {@code null} when the message is a
     * true duplicate (the row is already {@code SENT}). A row left in
     * {@code PENDING} or {@code FAILED} by a previous attempt is a
     * legitimate retry and is reused.
     */
    public NotificationLog acquire(NotificationMessage message) {
        Optional<NotificationLog> existing = logRepository.findByNotificationId(message.notificationId());
        if (existing.isEmpty()) {
            try {
                return logRepository.saveAndFlush(new NotificationLog(
                        message.notificationId(),
                        message.channel(),
                        message.recipient().userId(),
                        message.templateId(),
                        NotificationStatus.PENDING
                ));
            } catch (DataIntegrityViolationException dive) {
                // Concurrent insert won the UNIQUE index: fall through to the existing row.
                existing = logRepository.findByNotificationId(message.notificationId());
            }
        }
        if (existing.isEmpty()) {
            return null;
        }
        NotificationLog row = existing.get();
        NotificationStatus status = row.getStatus();
        if (status == NotificationStatus.PENDING || status == NotificationStatus.FAILED) {
            return row;
        }
        if (status == NotificationStatus.SENT) {
            row.markDuplicate();
            logRepository.save(row);
        }
        return null;
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void markSent(NotificationLog row, String provider) {
        row.markSent(provider);
        logRepository.save(row);
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void markFailed(NotificationLog row, String errorMessage) {
        row.markFailed("auto", errorMessage);
        logRepository.save(row);
    }
}
