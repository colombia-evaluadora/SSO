package com.co.eurekatic.notificationservice.domain;

/**
 * Status of a single notification attempt. Stored in
 * {@code notification_log.status}; checked by the
 * {@code chk_notification_log_status} CHECK constraint at
 * the DB level.
 */
public enum NotificationStatus {
    PENDING,
    SENT,
    FAILED,
    DUPLICATE
}
