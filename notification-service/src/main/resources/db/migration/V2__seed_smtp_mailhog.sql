-- =============================================================
-- notification-service V2: dev-visibility EMAIL fallback.
-- =============================================================
-- smtp-brevo / smtp-gmail need real credentials (SMTP_BREVO_*,
-- SMTP_GMAIL_*) and self-disable without them (see
-- SmtpEmailProvider#isConfigured). Without this row, a dev
-- stack with no real credentials collapses straight to
-- fake-email (priority 999), which only logs — nothing lands
-- in MailHog even though SMTP_HOST/SMTP_PORT already point at
-- it (see application.yml).
--
-- smtp-mailhog closes that gap: same SMTP impl, no
-- username_env/password_env keys at all, so it needs no
-- credentials and is always configured. Priority 50 keeps it
-- below the real providers (1/3) — set real credentials in any
-- environment and those win again automatically — and above
-- fake-email (999).
-- =============================================================

INSERT INTO provider_config
    (channel, provider_key, impl, enabled, priority, weight, policy, settings)
VALUES
    ('EMAIL', 'smtp-mailhog', 'SMTP', TRUE, 50, 1, 'PRIORITY',
        jsonb_build_object(
            'host', 'mailhog',
            'port', 1025,
            'starttls', false,
            'from', 'no-reply@example.com'
        ))
ON CONFLICT (channel, provider_key) DO NOTHING;
