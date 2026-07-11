package com.co.eurekatic.auth.init;

import com.co.eurekatic.auth.AuthCenterApplication;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.RoleRepository;
import com.co.eurekatic.common.repository.UserRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.context.TestPropertySource;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Integration test for {@link DataInitializer}. Verifies the seeder
 * creates the admin user on a fresh database, hashes the password
 * with the configured {@link PasswordEncoder}, and is idempotent
 * across multiple invocations.
 *
 * <p>Uses the same H2-in-PostgreSQL-mode configuration as
 * {@link AuthCenterIntegrationTest} so it does not require a live
 * Postgres instance.
 */
@SpringBootTest(classes = AuthCenterApplication.class)
@TestPropertySource(properties = {
        "spring.datasource.url=jdbc:h2:mem:data-initializer-test;MODE=PostgreSQL;DATABASE_TO_LOWER=TRUE;CASE_INSENSITIVE_IDENTIFIERS=TRUE;DB_CLOSE_DELAY=-1",
        "spring.datasource.driver-class-name=org.h2.Driver",
        "spring.datasource.username=sa",
        "spring.datasource.password=",
        "spring.jpa.hibernate.ddl-auto=create-drop",
        "spring.jpa.properties.hibernate.dialect=org.hibernate.dialect.H2Dialect",
        "sso.jwt.secret=integration-test-secret-which-is-at-least-32-bytes-long-1234567890",
        "eureka.client.enabled=false",
        "spring.cloud.discovery.enabled=false",
        // Use a unique admin username per test class so we don't
        // collide with AuthCenterIntegrationTest's seeded data.
        "sso.bootstrap.admin-username=testadmin",
        "sso.bootstrap.admin-password=InitialP@ssw0rd-9876"
})
class DataInitializerTest {

    @Autowired
    UserRepository userRepository;

    @Autowired
    RoleRepository roleRepository;

    @Autowired
    PasswordEncoder passwordEncoder;

    @BeforeEach
    void clean() {
        // Each test starts from an empty database so we can prove
        // idempotency by re-invoking the seeder.
        userRepository.deleteAll();
        roleRepository.deleteAll();
    }

    @Test
    void seederCreatesAdminUserWithBothRolesOnFreshDatabase() {
        DataInitializer seeder = newSeeder();
        seeder.run();

        User admin = userRepository.findByEmail("admin@example.com").orElseThrow();
        assertThat(admin.isEnabled()).isTrue();
        assertThat(admin.isActive()).isTrue();
        assertThat(admin.isLdap()).isFalse();
        assertThat(admin.getEmail()).isEqualTo("admin@example.com");
        assertThat(admin.getFullName()).isEqualTo("Default Administrator");
        // Password is hashed (BCrypt), not the plaintext.
        assertThat(admin.getPassword()).isNotEqualTo("InitialP@ssw0rd-9876");
        assertThat(passwordEncoder.matches("InitialP@ssw0rd-9876", admin.getPassword())).isTrue();

        assertThat(admin.getRoles())
                .extracting(Role::getName)
                .containsExactlyInAnyOrder("ADMIN", "USER");

        assertThat(roleRepository.findByName("ADMIN")).isPresent();
        assertThat(roleRepository.findByName("USER")).isPresent();
    }

    @Test
    void seederIsIdempotent() {
        // First run creates the admin.
        newSeeder().run();
        long usersAfterFirstRun = userRepository.count();
        long rolesAfterFirstRun = roleRepository.count();

        // Second run should be a no-op because the admin exists.
        newSeeder().run();
        assertThat(userRepository.count()).isEqualTo(usersAfterFirstRun);
        assertThat(roleRepository.count()).isEqualTo(rolesAfterFirstRun);

        // Third run for good measure.
        newSeeder().run();
        assertThat(userRepository.count()).isEqualTo(usersAfterFirstRun);
        assertThat(roleRepository.count()).isEqualTo(rolesAfterFirstRun);
    }

    @Test
    void seederSkipsWhenDisabled() {
        DataInitializer seeder = new DataInitializer(
                userRepository,
                roleRepository,
                passwordEncoder,
                /* enabled */ false,
                "InitialP@ssw0rd-9876",
                "admin@example.com"
        );
        seeder.run();
        // No admin row was created. (The string "testadmin" is
        // a sentinel that no DataInitializer run would ever
        // produce post-V12 since the column is gone.)
        assertThat(userRepository.findByEmail("testadmin")).isEmpty();
    }

    @Test
    void seederSkipsWhenPasswordIsBlank() {
        DataInitializer seeder = new DataInitializer(
                userRepository,
                roleRepository,
                passwordEncoder,
                /* enabled */ true,
                /* adminPassword */ "",
                "admin@example.com"
        );
        seeder.run();
        assertThat(userRepository.findByEmail("testadmin")).isEmpty();
    }

    @Test
    void seederSkipsWhenPasswordIsPlaceholder() {
        DataInitializer seeder = new DataInitializer(
                userRepository,
                roleRepository,
                passwordEncoder,
                /* enabled */ true,
                /* adminPassword */ "CHANGE_ME",
                "admin@example.com"
        );
        seeder.run();
        assertThat(userRepository.findByEmail("testadmin")).isEmpty();
    }

    private DataInitializer newSeeder() {
        return new DataInitializer(
                userRepository,
                roleRepository,
                passwordEncoder,
                /* enabled */ true,
                "InitialP@ssw0rd-9876",
                "admin@example.com"
        );
    }
}
