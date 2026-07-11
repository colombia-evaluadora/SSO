package com.co.eurekatic.notificationservice.repository;

import com.co.eurekatic.notificationservice.domain.NotificationLog;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

import java.util.Optional;
import java.util.UUID;

@Repository
public interface NotificationLogRepository extends JpaRepository<NotificationLog, Long> {

    /**
     * Look up an existing log row by its idempotency key.
     * The processor uses the UNIQUE constraint on
     * {@code notification_id} as the source of truth
     * (catching {@code DataIntegrityViolationException}
     * from {@code save()}) — this finder is the read-side
     * for the rare "show me the current state" path.
     */
    Optional<NotificationLog> findByNotificationId(UUID notificationId);
}
