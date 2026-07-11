-- =============================================================================
-- V1 — auth schema: users / role / role_users.
--
-- Ported from the legacy postgres/init/01-create-sso-db.sh. The `sso`
-- database itself is created by the postgres image (POSTGRES_DB=sso);
-- Flyway only owns the tables inside it. auth-center runs with
-- spring.jpa.hibernate.ddl-auto=validate, so this schema MUST exist
-- before it starts — the Flyway container migrates before the apps boot.
-- =============================================================================

-- The legacy schema names its tables `users` and `role` (a reserved
-- word, hence quoted where needed). Hibernate maps to these names via
-- the @Table / @Column annotations on the entities.
CREATE TABLE IF NOT EXISTS users (
    id_user                 BIGSERIAL    PRIMARY KEY,
    username                VARCHAR(80)  NOT NULL UNIQUE,
    full_name               VARCHAR(200),
    email                   VARCHAR(200),
    password                VARCHAR(68),
    enabled                 BOOLEAN      NOT NULL DEFAULT TRUE,
    account_non_expired     BOOLEAN      NOT NULL DEFAULT TRUE,
    account_non_locked      BOOLEAN      NOT NULL DEFAULT TRUE,
    credentials_non_expired BOOLEAN      NOT NULL DEFAULT TRUE,
    active                  BOOLEAN      NOT NULL DEFAULT TRUE,
    ldap                    BOOLEAN      NOT NULL DEFAULT FALSE,
    refresh_token           VARCHAR(64),
    api_token               VARCHAR(64),
    token_activation        VARCHAR(64),
    token_restore           VARCHAR(64)
);

CREATE TABLE IF NOT EXISTS role (
    id_role     BIGSERIAL    PRIMARY KEY,
    name        VARCHAR(60)  NOT NULL UNIQUE,
    description VARCHAR(200)
);

CREATE TABLE IF NOT EXISTS role_users (
    user_id BIGINT NOT NULL REFERENCES users(id_user)  ON DELETE CASCADE,
    role_id BIGINT NOT NULL REFERENCES role(id_role)   ON DELETE CASCADE,
    PRIMARY KEY (user_id, role_id)
);

-- Index for the lookup auth-center does on every request (loadUserByUsername).
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
