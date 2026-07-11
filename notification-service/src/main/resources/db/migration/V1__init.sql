-- =============================================================
-- notification-service V1: notification_log + provider_config
-- =============================================================
-- Creates both tables in a single migration per the spec
-- ("misma migración Flyway"), with the seed rows the
-- ProviderRegistry loads at startup.
--
-- The seed enables only the operators that have safe
-- dev defaults: twilio (SMS), smtp-brevo (EMAIL), fcm
-- (PUSH). All others are inserted as `enabled = false`
-- — the operator flips them on via SQL + a POST to
-- /actuator/providers/refresh once credentials land.
--
-- A provider enabled in this table whose required env
-- vars are absent at startup will self-disable with a
-- WARN log (never block startup).
-- =============================================================

CREATE TABLE IF NOT EXISTS notification_log (
    id                  BIGSERIAL    PRIMARY KEY,
    notification_id     UUID         NOT NULL UNIQUE,
    channel             VARCHAR(10)  NOT NULL,
    recipient_user_id   VARCHAR(100),
    template_id         VARCHAR(100) NOT NULL,
    status              VARCHAR(15)  NOT NULL,
    provider            VARCHAR(30),
    error_message       TEXT,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_notification_log_status CHECK (
        status IN ('PENDING','SENT','FAILED','DUPLICATE')
    ),
    CONSTRAINT chk_notification_log_channel CHECK (
        channel IN ('SMS','EMAIL','PUSH')
    )
);
CREATE INDEX IF NOT EXISTS idx_notification_log_channel_status
    ON notification_log (channel, status);
CREATE INDEX IF NOT EXISTS idx_notification_log_created_at
    ON notification_log (created_at);

CREATE TABLE IF NOT EXISTS provider_config (
    id           BIGSERIAL    PRIMARY KEY,
    channel      VARCHAR(10)  NOT NULL,
    provider_key VARCHAR(30)  NOT NULL,
    impl         VARCHAR(20)  NOT NULL,
    enabled      BOOLEAN      NOT NULL DEFAULT TRUE,
    priority     INT          NOT NULL DEFAULT 100,
    weight       INT          NOT NULL DEFAULT 1,
    policy       VARCHAR(10)  NOT NULL DEFAULT 'PRIORITY',
    settings     JSONB        NOT NULL DEFAULT '{}'::jsonb,
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_provider_config_channel_key
        UNIQUE (channel, provider_key),
    CONSTRAINT chk_provider_config_impl CHECK (
        impl IN ('SMTP','RESEND','EMAILJS','TWILIO','VONAGE','FCM','FAKE')
    ),
    CONSTRAINT chk_provider_config_policy CHECK (
        policy IN ('PRIORITY','WEIGHTED')
    )
);

-- ---- seed: SMS -------------------------------------------------
INSERT INTO provider_config
    (channel, provider_key, impl, enabled, priority, weight, policy, settings)
VALUES
    ('SMS', 'twilio', 'TWILIO', TRUE,  1, 1, 'PRIORITY', '{}'::jsonb),
    ('SMS', 'vonage', 'VONAGE', FALSE, 2, 1, 'PRIORITY', '{}'::jsonb)
ON CONFLICT (channel, provider_key) DO NOTHING;

-- ---- seed: EMAIL ----------------------------------------------
-- smtp-brevo is the recommended primary: relay at
-- smtp-relay.brevo.com:587, STARTTLS, daily free tier.
INSERT INTO provider_config
    (channel, provider_key, impl, enabled, priority, weight, policy, settings)
VALUES
    ('EMAIL', 'smtp-brevo', 'SMTP', TRUE, 1, 1, 'PRIORITY',
        jsonb_build_object(
            'host', 'smtp-relay.brevo.com',
            'port', 587,
            'starttls', true,
            'username_env', 'SMTP_BREVO_USER',
            'password_env', 'SMTP_BREVO_PASS',
            'from', 'no-reply@example.com'
        )),
    ('EMAIL', 'resend', 'RESEND', FALSE, 2, 1, 'PRIORITY',
        jsonb_build_object(
            'api_base', 'https://api.resend.com',
            'from', 'no-reply@example.com',
            'api_key_env', 'RESEND_API_KEY'
        )),
    ('EMAIL', 'smtp-gmail', 'SMTP', FALSE, 3, 1, 'PRIORITY',
        jsonb_build_object(
            'host', 'smtp.gmail.com',
            'port', 587,
            'starttls', true,
            'username_env', 'SMTP_GMAIL_USER',
            'password_env', 'SMTP_GMAIL_PASS',
            'from', 'no-reply@example.com'
        )),
    ('EMAIL', 'emailjs', 'EMAILJS', FALSE, 4, 1, 'PRIORITY',
        jsonb_build_object(
            'api_base', 'https://api.emailjs.com/api/v1.0/email/send',
            'service_id_env', 'EMAILJS_SERVICE_ID',
            'public_key_env', 'EMAILJS_PUBLIC_KEY',
            'private_key_env', 'EMAILJS_PRIVATE_KEY',
            'template_id', 'passthrough',
            'from', 'no-reply@example.com'
        ))
ON CONFLICT (channel, provider_key) DO NOTHING;

-- ---- seed: PUSH -----------------------------------------------
INSERT INTO provider_config
    (channel, provider_key, impl, enabled, priority, weight, policy, settings)
VALUES
    ('PUSH', 'fcm', 'FCM', TRUE, 1, 1, 'PRIORITY',
        jsonb_build_object(
            'credentials_env', 'GOOGLE_APPLICATION_CREDENTIALS',
            'project_id', '<filled from the FCM service-account JSON key file>'
        ))
ON CONFLICT (channel, provider_key) DO NOTHING;

-- ---- seed: fakes (always disabled in production) -------------
-- Tests flip these to enabled=TRUE on demand; in production
-- the operator never enables them. Priority 999 puts them
-- last in PRIORITY mode (i.e. only used as the very last
-- fallback), and they have weight 1 so they're irrelevant
-- under WEIGHTED too.
INSERT INTO provider_config
    (channel, provider_key, impl, enabled, priority, weight, policy, settings)
VALUES
    ('SMS',   'fake-sms',   'FAKE', FALSE, 999, 1, 'PRIORITY', '{}'::jsonb),
    ('EMAIL', 'fake-email', 'FAKE', FALSE, 999, 1, 'PRIORITY', '{}'::jsonb),
    ('PUSH',  'fake-push',  'FAKE', FALSE, 999, 1, 'PRIORITY', '{}'::jsonb)
ON CONFLICT (channel, provider_key) DO NOTHING;
