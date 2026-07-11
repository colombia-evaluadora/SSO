package com.co.eurekatic.common.entity;

import com.co.eurekatic.common.TestJpaConfig;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.common.repository.UserRepository;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.data.jpa.test.autoconfigure.DataJpaTest;
import org.springframework.boot.jpa.test.autoconfigure.TestEntityManager;
import org.springframework.test.context.ContextConfiguration;
import org.springframework.test.context.TestPropertySource;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Verifies the JPA mapping and the User ↔ Role many-to-many relationship on
 * an in-memory H2 database. Replaces the legacy tests that ran against
 * the production Postgres schema.
 */
@DataJpaTest
@ContextConfiguration(classes = TestJpaConfig.class)
@TestPropertySource(properties = {
        "spring.datasource.url=jdbc:h2:mem:test;MODE=PostgreSQL;DB_CLOSE_DELAY=-1",
        "spring.datasource.driver-class-name=org.h2.Driver",
        "spring.datasource.username=sa",
        "spring.datasource.password=",
        "spring.jpa.hibernate.ddl-auto=create-drop",
        "spring.jpa.database-platform=org.hibernate.dialect.H2Dialect"
})
class UserRoleMappingTest {

    @Autowired
    private TestEntityManager em;

    @Autowired
    private UserRepository userRepository;

    @Autowired
    private RoleRepository roleRepository;

    @Test
    void userPersistsAndRoundTripsWithRoles() {
        // given
        Role admin = roleRepository.save(new Role("ADMIN", "Administrator role"));
        Role user = roleRepository.save(new Role("USER", "Standard user role"));

        User alice = new User("alice@example.com", "{noop}not-actually-bcrypted-here");
        alice.setFullName("Alice Adams");
        alice.addRole(admin);
        alice.addRole(user);

        // when
        User saved = userRepository.save(alice);
        em.flush();
        em.clear();

        // then — round-trip
        User found = userRepository.findByEmail("alice@example.com")
                .orElseThrow(() -> new AssertionError("alice not found"));

        assertThat(found.getId()).isEqualTo(saved.getId());
        assertThat(found.getEmail()).isEqualTo("alice@example.com");
        assertThat(found.getRoles())
                .extracting(Role::getName)
                .containsExactlyInAnyOrder("ADMIN", "USER");
    }

    @Test
    void userDetailsContractReflectsEntityState() {
        // given — a fully-active user with roles
        Role admin = roleRepository.save(new Role("ADMIN"));
        User u = new User("bob@example.com", "$2a$10$dummy");
        u.setEnabled(true);
        u.setActive(true);
        u.setAccountNonExpired(true);
        u.setAccountNonLocked(true);
        u.setCredentialsNonExpired(true);
        u.addRole(admin);
        userRepository.save(u);
        em.flush();
        em.clear();

        // when
        User found = userRepository.findByEmail("bob@example.com").orElseThrow();

        // then
        assertThat(found.isEnabled()).isTrue();
        assertThat(found.isAccountNonExpired()).isTrue();
        assertThat(found.isAccountNonLocked()).isTrue();
        assertThat(found.isCredentialsNonExpired()).isTrue();
        assertThat(found.getAuthorities())
                .extracting("authority")
                .containsExactly("ADMIN");
    }

    @Test
    void disabledUserIsNotEnabled() {
        // given
        User u = new User("carol@example.com", "$2a$10$dummy");
        u.setEnabled(false);
        u.setActive(true);
        userRepository.save(u);
        em.flush();
        em.clear();

        // when
        User found = userRepository.findByEmail("carol@example.com").orElseThrow();

        // then — isEnabled() requires both enabled=true AND active=true
        assertThat(found.isEnabled()).isFalse();
    }

    @Test
    void findByNameReturnsRole() {
        roleRepository.save(new Role("EDITOR"));
        assertThat(roleRepository.findByName("EDITOR"))
                .isPresent()
                .get()
                .extracting(Role::getName)
                .isEqualTo("EDITOR");
        assertThat(roleRepository.findByName("MISSING")).isEmpty();
    }
}
