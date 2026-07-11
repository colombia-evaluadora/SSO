-- =============================================================================
-- V13 — expiry timestamps for the activation and restore-password tokens.
--
-- Background: TokenService issued both tokens as bare UUIDs with no
-- expiry (see its javadoc, now stale) — a token was only invalidated
-- by being consumed. The activation/restore emails already advertise
-- a TTL ("ttlMinutes": 60 / 30 in UserAdminService's event payload),
-- but that number was purely decorative; nothing enforced it. This
-- migration adds the columns TokenService needs to make it real, and
-- to give "resend activation" a meaningful reason to exist (reissue
-- because the old one expired).
--
-- Both columns are nullable: NULL means "no token currently issued"
-- (mirrors token_activation/token_restore themselves, which are also
-- nullable and cleared on consume).
-- =============================================================================

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS token_activation_expires_at TIMESTAMPTZ NULL,
    ADD COLUMN IF NOT EXISTS token_restore_expires_at    TIMESTAMPTZ NULL;
