package com.co.eurekatic.auth.security;

import org.postgresql.PGConnection;
import org.postgresql.PGNotification;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.SmartLifecycle;
import org.springframework.stereotype.Component;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * Listens on the Postgres channel {@code sso_user_roles_changed} and drops the
 * cached role set of every email it receives.
 *
 * <h2>Why</h2>
 * <p>{@link CachedEffectiveRolesResolver} caches roles for an hour and they end
 * up in the JWT {@code roles} claim. Only sso-admin invalidated it, but roles
 * are also revoked from SQL (query-service permission endpoints, the
 * TSEDE_USUARIO resync trigger, PIGSE functions). A trigger on
 * {@code public.role_users} now emits {@code pg_notify} with the user's email
 * on commit, whatever the writer.
 *
 * <h2>Connection</h2>
 * <p>LISTEN needs a session that stays open, so this uses its own JDBC
 * connection instead of borrowing one from the Hikari pool forever. When it
 * (re)connects it drops the whole role cache: notifications sent while it was
 * down are not queued by Postgres. On failure it retries with backoff; the
 * cache TTL remains the upper bound on staleness.
 *
 * <p>Every replica listens and deletes the same key: the delete is idempotent.
 * Only active against a PostgreSQL URL (tests run on H2).
 */
@Component
@ConditionalOnProperty(prefix = "sso.session.user-roles.listener", name = "enabled",
        havingValue = "true", matchIfMissing = true)
public class RoleChangeListener implements SmartLifecycle {

    static final String CHANNEL = "sso_user_roles_changed";

    private static final Logger log = LoggerFactory.getLogger(RoleChangeListener.class);
    private static final int POLL_TIMEOUT_MS = 10_000;
    private static final long MAX_BACKOFF_MS = 60_000;

    private final UserRolesCacheInvalidator invalidator;
    private final String url;
    private final String username;
    private final String password;

    private volatile boolean running;
    private volatile Thread worker;
    private volatile Connection connection;

    public RoleChangeListener(UserRolesCacheInvalidator invalidator,
                              @Value("${spring.datasource.url:}") String url,
                              @Value("${spring.datasource.username:}") String username,
                              @Value("${spring.datasource.password:}") String password) {
        this.invalidator = invalidator;
        this.url = url;
        this.username = username;
        this.password = password;
    }

    @Override
    public void start() {
        if (!url.startsWith("jdbc:postgresql:")) {
            log.info("Role change listener disabled: datasource is not PostgreSQL");
            return;
        }
        running = true;
        worker = Thread.ofPlatform().daemon().name("role-change-listener").start(this::loop);
    }

    @Override
    public void stop() {
        running = false;
        closeQuietly();
        Thread t = worker;
        if (t != null) {
            t.interrupt();
        }
    }

    @Override
    public boolean isRunning() {
        return running;
    }

    private void loop() {
        long backoff = 1_000;
        while (running) {
            try (Connection conn = DriverManager.getConnection(url, username, password)) {
                connection = conn;
                try (Statement st = conn.createStatement()) {
                    st.execute("LISTEN " + CHANNEL);
                }
                invalidator.invalidateAll();
                log.info("Listening for role changes on channel {}", CHANNEL);
                backoff = 1_000;
                PGConnection pg = conn.unwrap(PGConnection.class);
                while (running) {
                    PGNotification[] notifications = pg.getNotifications(POLL_TIMEOUT_MS);
                    if (notifications == null) {
                        continue;
                    }
                    for (PGNotification n : notifications) {
                        invalidator.invalidate(n.getParameter());
                    }
                }
            } catch (SQLException e) {
                if (!running) {
                    return;
                }
                log.warn("Role change listener lost its connection; retrying in {} ms", backoff, e);
                try {
                    Thread.sleep(backoff);
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    return;
                }
                backoff = Math.min(backoff * 2, MAX_BACKOFF_MS);
            } finally {
                connection = null;
            }
        }
    }

    private void closeQuietly() {
        Connection c = connection;
        if (c != null) {
            try {
                c.close();
            } catch (SQLException ignored) {
                // Shutting down; the worker exits on the resulting error.
            }
        }
    }
}
