-- =============================================================================
-- V2 — sso-admin Phase 1: groups / user_group.
-- Ported from postgres/init/02-create-sso-admin-tables.sh.
-- =============================================================================

-- GROUPS: a named collection of users, used for coarse-grained access
-- scoping. Distinct from ROLE (per-user, fine-grained). Mirrors the
-- legacy GROUPS table from sso-service.
CREATE TABLE IF NOT EXISTS groups (
    id_group    BIGSERIAL    PRIMARY KEY,
    name        VARCHAR(120) NOT NULL UNIQUE,
    description VARCHAR(255)
);

-- user_group: M:N between users and groups. Owning side is the Group
-- entity (common/.../entity/Group.java) — JPA reads/writes via groups.
CREATE TABLE IF NOT EXISTS user_group (
    group_id BIGINT NOT NULL REFERENCES groups(id_group) ON DELETE CASCADE,
    user_id  BIGINT NOT NULL REFERENCES users(id_user)  ON DELETE CASCADE,
    PRIMARY KEY (group_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_groups_name ON groups(name);
