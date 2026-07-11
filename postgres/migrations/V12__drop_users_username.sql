-- =============================================================================
-- V12 — drop the users.username column. Login identity moves to email.
--
-- Background: prior to this migration, the auth schema carried BOTH a
-- `username` column (the login identifier) and an `email` column (used
-- only for notifications). Going forward, email IS the login identifier:
-- the JWT `sub` carries it, the api-gateway forwards it as
-- X-Authenticated-User, and downstream services resolve roles by it.
-- This migration removes `username` permanently so the two
-- identifiers can't drift out of sync.
--
-- Safety:
--   1. Pre-flight: refuse the migration if any row has NULL or empty
--      email. Email is the new login identifier; a NULL email means
--      that row can NEVER log in again. We refuse rather than silently
--      backfill — operator must set a valid email before re-running.
--   2. The dev/admin seed (`auth-center/.../init/DataInitializer`)
--      already sets both username='admin' and email='admin@example.com',
--      so a fresh dev environment passes the pre-flight automatically.
--   3. In dev / docker-compose a Postgres volume wipe is the simplest
--      way to recover; in prod the operator runs an UPDATE before
--      applying V12.
-- =============================================================================

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM users WHERE email IS NULL OR email = ''
    ) THEN
        RAISE EXCEPTION
            'cannot drop users.username: one or more rows have NULL/empty email; '
            'update them to a valid email and re-run';
    END IF;
END $$;

-- Drop the explicit lookup index (UNIQUE below has its own backing
-- index, but the legacy name is more discoverable in older EXPLAINs).
DROP INDEX IF EXISTS idx_users_username;

-- Drop the UNIQUE constraint that backed Spring Data's
-- findByUsername / existsByUsername derived queries.
DO $$
DECLARE
    cons_name text;
BEGIN
    SELECT conname INTO cons_name
    FROM pg_constraint
    WHERE conrelid = 'users'::regclass
      AND contype = 'u'
      AND pg_get_constraintdef(oid) ILIKE '%(username)%';
    IF cons_name IS NOT NULL THEN
        EXECUTE format('ALTER TABLE users DROP CONSTRAINT %I', cons_name);
    END IF;
END $$;

-- Promote email to the new login identifier.
ALTER TABLE users ALTER COLUMN email SET NOT NULL;

-- Idempotent UNIQUE on email: keeps an existing constraint (we may
-- be re-running on a half-applied environment) and otherwise adds one.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'users'::regclass
          AND contype = 'u'
          AND pg_get_constraintdef(oid) ILIKE '%(email)%'
    ) THEN
        ALTER TABLE users ADD CONSTRAINT users_email_key UNIQUE (email);
    END IF;
END $$;

-- Drop the legacy column now that nothing references it.
ALTER TABLE users DROP COLUMN username;
