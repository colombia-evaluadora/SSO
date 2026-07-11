-- =============================================================================
-- V11 — group_role: M:N between GROUPS and ROLE. Turns groups into RBAC
-- role bundles. A user's effective roles = direct roles (role_users) ∪ the
-- roles of every group they belong to (user_group -> group_role).
-- =============================================================================
CREATE TABLE IF NOT EXISTS group_role (
    group_id BIGINT NOT NULL REFERENCES groups(id_group) ON DELETE CASCADE,
    role_id  BIGINT NOT NULL REFERENCES role(id_role)    ON DELETE CASCADE,
    PRIMARY KEY (group_id, role_id)
);

CREATE INDEX IF NOT EXISTS idx_group_role_role ON group_role(role_id);
