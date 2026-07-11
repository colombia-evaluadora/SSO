package com.co.eurekatic.notificationservice.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.Instant;
import java.util.UUID;

/**
 * JPA entity for the {@code notification_log} table.
 *
 * <p>The {@code @Column} names use lowercase to match the
 * identifiers Postgres stores (Postgres folds unquoted
 * identifiers to lowercase; the schema DDL in
 * {@code V1__init.sql} uses lowercase, so the entity must
 * match — see the project memory note "Hibernate 7.x
 * with ddl-auto=validate: schema must match entities").
 *
 * <p>Fields map 1-1 to the spec's {@code notification_log}
 * table. {@code notificationId} is the idempotency key
 * (UNIQUE constraint) — a second message with the same
 * value triggers a {@code DataIntegrityViolationException}
 * that the processor catches and translates to a
 * {@code DUPLICATE} log row, then ACKs the original
 * RabbitMQ message.
 */
@Entity
@Table(name = "notification_log")
public class NotificationLog {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "id")
    private Long id;

    @Column(name = "notification_id", nullable = false, unique = true)
    private UUID notificationId;

    @Enumerated(EnumType.STRING)
    @Column(name = "channel", nullable = false, length = 10)
    private Channel channel;

    @Column(name = "recipient_user_id", length = 100)
    private String recipientUserId;

    @Column(name = "template_id", nullable = false, length = 100)
    private String templateId;

    @Enumerated(EnumType.STRING)
    @Column(name = "status", nullable = false, length = 15)
    private NotificationStatus status;

    @Column(name = "provider", length = 30)
    private String provider;

    @Column(name = "error_message", columnDefinition = "text")
    private String errorMessage;

    @Column(name = "created_at", nullable = false)
    private Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    protected NotificationLog() {
        // JPA
    }

    public NotificationLog(UUID notificationId,
                           Channel channel,
                           String recipientUserId,
                           String templateId,
                           NotificationStatus status) {
        this.notificationId = notificationId;
        this.channel = channel;
        this.recipientUserId = recipientUserId;
        this.templateId = templateId;
        this.status = status;
        Instant now = Instant.now();
        this.createdAt = now;
        this.updatedAt = now;
    }

    public void markSent(String provider) {
        this.status = NotificationStatus.SENT;
        this.provider = provider;
        this.errorMessage = null;
        this.updatedAt = Instant.now();
    }

    public void markFailed(String provider, String errorMessage) {
        this.status = NotificationStatus.FAILED;
        this.provider = provider;
        this.errorMessage = truncate(errorMessage, 4000);
        this.updatedAt = Instant.now();
    }

    public void markDuplicate() {
        this.status = NotificationStatus.DUPLICATE;
        this.updatedAt = Instant.now();
    }

    private static String truncate(String s, int max) {
        if (s == null) return null;
        return s.length() <= max ? s : s.substring(0, max);
    }

    public Long getId() { return id; }
    public UUID getNotificationId() { return notificationId; }
    public Channel getChannel() { return channel; }
    public String getRecipientUserId() { return recipientUserId; }
    public String getTemplateId() { return templateId; }
    public NotificationStatus getStatus() { return status; }
    public String getProvider() { return provider; }
    public String getErrorMessage() { return errorMessage; }
    public Instant getCreatedAt() { return createdAt; }
    public Instant getUpdatedAt() { return updatedAt; }
}
