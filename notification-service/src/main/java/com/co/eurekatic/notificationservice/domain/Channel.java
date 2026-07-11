package com.co.eurekatic.notificationservice.domain;

/**
 * Notification channel. The spec's top-level routing key —
 * one queue + one DLQ per channel.
 */
public enum Channel {
    SMS,
    EMAIL,
    PUSH
}
