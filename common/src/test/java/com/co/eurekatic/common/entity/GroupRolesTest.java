package com.co.eurekatic.common.entity;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.assertThat;

class GroupRolesTest {

    @Test
    void addRoleThenRemoveRoleMutatesTheRoleSet() {
        Group g = new Group("ops", "operators");
        Role r = new Role();
        r.setName("QUERY_READER");

        g.addRole(r);
        assertThat(g.getRoles()).containsExactly(r);

        g.removeRole(r);
        assertThat(g.getRoles()).isEmpty();
    }
}
