# Groups as Role Bundles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the orphaned `groups` CRUD into RBAC role bundles: a group aggregates roles, and a user's effective roles (direct ∪ group roles) are stamped into the JWT at issue time so the existing role-driven access model needs no changes.

**Architecture:** Add a `group_role` join and a `Group.roles` relation. Compute effective roles via a single `EffectiveRolesResolver` (a JOIN-FETCH query + set union) invoked at the three auth-center token-issue sites. Expose group↔role binding endpoints in sso-admin mirroring the App pattern, and a "Roles" tab in the admin-ui group drawer.

**Tech Stack:** Spring Boot 4 / JDK 25, JPA/Hibernate, Flyway, JUnit Jupiter + Testcontainers, React 19 + TanStack Query + Vitest.

**Design source:** `docs/superpowers/specs/2026-07-07-groups-as-role-bundles-design.md`

---

## File Structure

- `postgres/migrations/V8__create_group_role.sql` — new join table (create).
- `common/.../entity/Group.java` — add `roles` relation + `addRole`/`removeRole` (modify).
- `common/.../repository/UserRepository.java` — add effective-roles JOIN FETCH query (modify).
- `auth-center/.../security/EffectiveRolesResolver.java` — resolve a username to its effective role-name set (create).
- `auth-center/.../security/JsonLoginFilter.java` — use the resolver at login (modify).
- `auth-center/.../web/RefreshController.java` — use the resolver on refresh (modify).
- `auth-center/.../web/AuthController.java` — use the resolver for the API token (modify).
- `auth-center/.../config/AuthenticationConfig.java` (or wherever JsonLoginFilter is built) — pass the resolver (modify).
- `sso-admin/.../service/GroupAdminService.java` — bind/unbind role + checked projection (modify).
- `sso-admin/.../controller/GroupController.java` — role endpoints (modify).
- `admin-ui/src/api/endpoints.ts` — group role endpoints (modify).
- `admin-ui/src/hooks/useGroups.ts` — role-binding hooks (modify).
- `admin-ui/src/pages/groups/GroupFormDrawer.tsx` — "Roles" tab (modify).

---

## Task 1: Flyway V8 — `group_role` join table

**Files:**
- Create: `postgres/migrations/V8__create_group_role.sql`

- [ ] **Step 1: Write the migration**

```sql
-- =============================================================================
-- V8 — group_role: M:N between GROUPS and ROLE. Turns groups into RBAC
-- role bundles. A user's effective roles = direct roles (role_users) ∪ the
-- roles of every group they belong to (user_group -> group_role).
-- =============================================================================
CREATE TABLE IF NOT EXISTS group_role (
    group_id BIGINT NOT NULL REFERENCES groups(id_group) ON DELETE CASCADE,
    role_id  BIGINT NOT NULL REFERENCES role(id_role)    ON DELETE CASCADE,
    PRIMARY KEY (group_id, role_id)
);

CREATE INDEX IF NOT EXISTS idx_group_role_role ON group_role(role_id);
```

- [ ] **Step 2: Verify Flyway accepts it against a fresh Postgres**

Run:
```bash
cd modernize && docker compose up -d postgres && \
docker compose run --rm flyway -connectRetries=30 migrate
```
Expected: `Successfully applied ... migrations` ending `now at version v8` (or `Schema is up to date` if the target DB already has it; against a fresh local `postgres` it applies V1..V8).

- [ ] **Step 3: Commit**

```bash
git add postgres/migrations/V8__create_group_role.sql
git commit -m "feat(db): add group_role join table (V8)"
```

---

## Task 2: `Group.roles` relation

**Files:**
- Modify: `common/src/main/java/com/co/eurekatic/common/entity/Group.java`
- Test: `common/src/test/java/com/co/eurekatic/common/entity/GroupRolesTest.java`

- [ ] **Step 1: Write the failing test**

```java
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `docker run --rm -v "$(pwd -W):/w" -w /w -v sso-maven-repo:/root/.m2 maven:3.9-eclipse-temurin-25 mvn -B -ntp -pl common test -Dtest=GroupRolesTest`
Expected: FAIL — `addRole`/`getRoles` not defined.

- [ ] **Step 3: Add the relation + methods to `Group.java`**

Add these fields/methods inside the `Group` class (after the `users` relation and its `addUser`/`removeUser`):

```java
    /**
     * Roles this group grants. A user in this group gains these roles
     * (in addition to their direct role_users roles) at token-issue
     * time — see auth-center's EffectiveRolesResolver.
     */
    @ManyToMany(fetch = FetchType.LAZY)
    @JoinTable(
            name = "group_role",
            joinColumns = @JoinColumn(name = "group_id"),
            inverseJoinColumns = @JoinColumn(name = "role_id"))
    @Setter(AccessLevel.NONE)
    private Set<Role> roles = new HashSet<>();

    public void addRole(Role role) {
        this.roles.add(role);
    }

    public void removeRole(Role role) {
        this.roles.remove(role);
    }
```

(`@ManyToMany`, `@JoinTable`, `@JoinColumn`, `FetchType`, `AccessLevel`, `Set`, `HashSet` are already imported for the `users` relation — no new imports.)

- [ ] **Step 4: Run test to verify it passes**

Run: `docker run --rm -v "$(pwd -W):/w" -w /w -v sso-maven-repo:/root/.m2 maven:3.9-eclipse-temurin-25 mvn -B -ntp -pl common test -Dtest=GroupRolesTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add common/src/main/java/com/co/eurekatic/common/entity/Group.java \
        common/src/test/java/com/co/eurekatic/common/entity/GroupRolesTest.java
git commit -m "feat(common): add Group.roles (group_role) relation"
```

---

## Task 3: `UserRepository` effective-roles fetch query

**Files:**
- Modify: `common/src/main/java/com/co/eurekatic/common/repository/UserRepository.java`

- [ ] **Step 1: Add the JOIN FETCH query**

Add inside the `UserRepository` interface (add `import org.springframework.data.jpa.repository.Query;` if not present):

```java
    /**
     * Loads a user with everything needed to compute effective roles in
     * a single round-trip: direct roles, groups, and each group's roles.
     * DISTINCT + Set collections avoid duplicate rows and
     * MultipleBagFetchException. Used only by auth-center's
     * EffectiveRolesResolver at token-issue time.
     */
    @Query("""
           SELECT DISTINCT u FROM User u
           LEFT JOIN FETCH u.roles
           LEFT JOIN FETCH u.groups g
           LEFT JOIN FETCH g.roles
           WHERE u.username = :username
           """)
    Optional<User> findByUsernameWithEffectiveRoles(String username);
```

- [ ] **Step 2: Compile common**

Run: `docker run --rm -v "$(pwd -W):/w" -w /w -v sso-maven-repo:/root/.m2 maven:3.9-eclipse-temurin-25 mvn -B -ntp -pl common -am compile`
Expected: BUILD SUCCESS.

- [ ] **Step 3: Commit**

```bash
git add common/src/main/java/com/co/eurekatic/common/repository/UserRepository.java
git commit -m "feat(common): UserRepository.findByUsernameWithEffectiveRoles fetch query"
```

---

## Task 4: `EffectiveRolesResolver`

**Files:**
- Create: `auth-center/src/main/java/com/co/eurekatic/auth/security/EffectiveRolesResolver.java`
- Test: `auth-center/src/test/java/com/co/eurekatic/auth/security/EffectiveRolesResolverTest.java`

- [ ] **Step 1: Write the failing test**

```java
package com.co.eurekatic.auth.security;

import com.co.eurekatic.common.entity.Group;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.UserRepository;
import org.junit.jupiter.api.Test;

import java.util.LinkedHashSet;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class EffectiveRolesResolverTest {

    private final UserRepository repo = mock(UserRepository.class);
    private final EffectiveRolesResolver resolver = new EffectiveRolesResolver(repo);

    private Role role(String name) { Role r = new Role(); r.setName(name); return r; }

    @Test
    void unionsDirectAndGroupRolesDeduplicated() {
        User u = new User();
        u.setUsername("alice");
        u.addRole(role("USER"));            // direct
        Group g = new Group("ops");
        g.addRole(role("QUERY_READER"));    // via group
        g.addRole(role("USER"));            // duplicate of direct
        u.getGroups().add(g);

        when(repo.findByUsernameWithEffectiveRoles("alice")).thenReturn(Optional.of(u));

        Set<String> roles = resolver.forUsername("alice");

        assertThat(roles).containsExactlyInAnyOrder("USER", "QUERY_READER");
    }

    @Test
    void unknownUserYieldsEmptySet() {
        when(repo.findByUsernameWithEffectiveRoles("ghost")).thenReturn(Optional.empty());
        assertThat(resolver.forUsername("ghost")).isEqualTo(new LinkedHashSet<String>());
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `docker run --rm -v "$(pwd -W):/w" -w /w -v sso-maven-repo:/root/.m2 maven:3.9-eclipse-temurin-25 mvn -B -ntp -pl auth-center -am test -Dtest=EffectiveRolesResolverTest`
Expected: FAIL — `EffectiveRolesResolver` does not exist.

- [ ] **Step 3: Write the resolver**

```java
package com.co.eurekatic.auth.security;

import com.co.eurekatic.common.entity.User;
import com.co.eurekatic.common.repository.UserRepository;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.util.LinkedHashSet;
import java.util.Set;

/**
 * Computes a user's effective roles for the JWT: their direct roles
 * (role_users) unioned with the roles of every group they belong to
 * (user_group -> group_role). Loaded in one fetch query so no lazy
 * traversal happens outside a session.
 */
@Component
public class EffectiveRolesResolver {

    private final UserRepository userRepository;

    public EffectiveRolesResolver(UserRepository userRepository) {
        this.userRepository = userRepository;
    }

    @Transactional(readOnly = true)
    public Set<String> forUsername(String username) {
        Set<String> names = new LinkedHashSet<>();
        userRepository.findByUsernameWithEffectiveRoles(username).ifPresent(user -> {
            user.getRoles().forEach(r -> names.add(r.getName()));
            user.getGroups().forEach(g -> g.getRoles().forEach(r -> names.add(r.getName())));
        });
        return names;
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker run --rm -v "$(pwd -W):/w" -w /w -v sso-maven-repo:/root/.m2 maven:3.9-eclipse-temurin-25 mvn -B -ntp -pl auth-center -am test -Dtest=EffectiveRolesResolverTest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add auth-center/src/main/java/com/co/eurekatic/auth/security/EffectiveRolesResolver.java \
        auth-center/src/test/java/com/co/eurekatic/auth/security/EffectiveRolesResolverTest.java
git commit -m "feat(auth): EffectiveRolesResolver (direct ∪ group roles)"
```

---

## Task 5: Use effective roles at the three token-issue sites

**Files:**
- Modify: `auth-center/src/main/java/com/co/eurekatic/auth/web/RefreshController.java`
- Modify: `auth-center/src/main/java/com/co/eurekatic/auth/web/AuthController.java`
- Modify: `auth-center/src/main/java/com/co/eurekatic/auth/security/JsonLoginFilter.java`
- Modify: `auth-center/src/main/java/com/co/eurekatic/auth/config/AuthenticationConfig.java` (JsonLoginFilter wiring — confirm path with `grep -rl "new JsonLoginFilter" auth-center/src/main`)
- Test: `auth-center/src/test/java/com/co/eurekatic/auth/GroupRolesInTokenIntegrationTest.java`

- [ ] **Step 1: Write the failing integration test**

Mirror the existing `AuthCenterIntegrationTest` bootstrap (same `@SpringBootTest` + Testcontainers Postgres setup — copy its class-level annotations and container wiring verbatim). The new test seeds a user whose ONLY path to a role is through a group, logs in, and asserts the role is in the JWT:

```java
package com.co.eurekatic.auth;

// Copy the imports + @SpringBootTest / @Testcontainers / @DynamicPropertySource
// container setup from AuthCenterIntegrationTest.

class GroupRolesInTokenIntegrationTest /* extends/uses same base as AuthCenterIntegrationTest */ {

    // Autowire UserRepository, GroupRepository, RoleRepository, PasswordEncoder,
    // and a WebTestClient/TestRestTemplate exactly as AuthCenterIntegrationTest does.

    @Test
    void loginJwtIncludesRolesGrantedOnlyViaGroup() {
        // 1. seed role QUERY_READER, a group "ops" bound to it,
        //    and user "bob" with password, NO direct roles, member of "ops".
        // 2. POST /login {username:"bob", password:"..."} -> capture token.
        // 3. decode the JWT payload (base64url of the middle segment) and
        //    assert the "roles" claim contains "QUERY_READER".
    }
}
```

Fill the seeding + login + decode using the same helpers `AuthCenterIntegrationTest` already provides (it already logs in and inspects tokens — reuse those helpers).

- [ ] **Step 2: Run it to verify it fails**

Run: `docker run --rm -v "$(pwd -W):/w" -w /w -v sso-maven-repo:/root/.m2 -v /var/run/docker.sock:/var/run/docker.sock maven:3.9-eclipse-temurin-25 mvn -B -ntp -pl auth-center -am test -Dtest=GroupRolesInTokenIntegrationTest`
Expected: FAIL — the group role is absent from the token (login still reads direct roles only).

- [ ] **Step 3: RefreshController — swap to the resolver**

Add a constructor-injected `EffectiveRolesResolver effectiveRoles` field (follow the existing constructor-injection style in the class). Replace the role-building block (currently):

```java
        Set<String> roles = user.getRoles().stream()
                .map(r -> r.getName())
                .collect(Collectors.toCollection(LinkedHashSet::new));
        String accessToken = jwt.issueAccessToken(user.getUsername(), roles);
```

with:

```java
        Set<String> roles = effectiveRoles.forUsername(user.getUsername());
        String accessToken = jwt.issueAccessToken(user.getUsername(), roles);
```

- [ ] **Step 4: AuthController — swap `roleNames` to the resolver**

Add a constructor-injected `EffectiveRolesResolver effectiveRoles` field (extend the existing 2-arg constructor to 3 args and set it). Replace the `roleNames(user)` call in `getApiToken` with `effectiveRoles.forUsername(user.getUsername())` and delete the now-unused private `roleNames(User u)` method.

- [ ] **Step 5: JsonLoginFilter — issue the token with effective roles**

Add `EffectiveRolesResolver effectiveRoles` as a final field + constructor param (append to the existing param list). Replace:

```java
        Set<String> roles = authResult.getAuthorities().stream()
                .map(GrantedAuthority::getAuthority)
                .collect(Collectors.toCollection(LinkedHashSet::new));
        String accessToken = jwt.issueAccessToken(username, roles);
```

with:

```java
        Set<String> roles = effectiveRoles.forUsername(username);
        String accessToken = jwt.issueAccessToken(username, roles);
```

Then update the wiring site (where `new JsonLoginFilter(...)` is called) to pass the `EffectiveRolesResolver` bean as the new last argument.

- [ ] **Step 6: Run the integration test to verify it passes**

Run: `docker run --rm -v "$(pwd -W):/w" -w /w -v sso-maven-repo:/root/.m2 -v /var/run/docker.sock:/var/run/docker.sock maven:3.9-eclipse-temurin-25 mvn -B -ntp -pl auth-center -am test -Dtest=GroupRolesInTokenIntegrationTest`
Expected: PASS — the JWT now carries the group-granted role.

- [ ] **Step 7: Run the full auth-center suite (regression)**

Run: `docker run --rm -v "$(pwd -W):/w" -w /w -v sso-maven-repo:/root/.m2 -v /var/run/docker.sock:/var/run/docker.sock maven:3.9-eclipse-temurin-25 mvn -B -ntp -pl auth-center -am test`
Expected: all green (login/refresh/api-token still work; direct-role-only users unchanged).

- [ ] **Step 8: Commit**

```bash
git add auth-center/src/main/java/com/co/eurekatic/auth/
git commit -m "feat(auth): stamp effective (direct ∪ group) roles into the JWT"
```

---

## Task 6: sso-admin — group↔role binding endpoints

**Files:**
- Modify: `sso-admin/src/main/java/com/co/eurekatic/ssoadmin/service/GroupAdminService.java`
- Modify: `sso-admin/src/main/java/com/co/eurekatic/ssoadmin/controller/GroupController.java`
- Test: `sso-admin/src/test/java/com/co/eurekatic/ssoadmin/service/GroupAdminServiceRolesTest.java`

- [ ] **Step 1: Write the failing service test**

Mirror the existing `GroupAdminServiceTest` setup (same mock/`@DataJpaTest` style it already uses — copy its wiring). Add:

```java
    @Test
    void bindRoleThenCheckedReflectsIt() {
        // seed a group + two roles (roleA bound, roleB not) via the repos
        // the existing GroupAdminServiceTest already wires.
        service.bindRole(groupId, roleAId);

        var checked = service.getRolesForGroupChecked(groupId);

        assertThat(checked).extracting(GroupAdminService.RoleChecked::checked)
                .containsExactlyInAnyOrder(true, false);
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `docker run --rm -v "$(pwd -W):/w" -w /w -v sso-maven-repo:/root/.m2 maven:3.9-eclipse-temurin-25 mvn -B -ntp -pl sso-admin -am test -Dtest=GroupAdminServiceRolesTest`
Expected: FAIL — `bindRole`/`getRolesForGroupChecked`/`RoleChecked` not defined on GroupAdminService.

- [ ] **Step 3: Add role binding to `GroupAdminService`**

Inject `RoleRepository roleRepository` (add to the constructor, mirroring `AppService`). Add (mirroring `AppService.bindRole`/`unbindRole`/`getRolesForAppChecked`):

```java
    @Transactional
    public void bindRole(Long groupId, Long roleId) {
        Group group = groupRepository.findById(groupId)
                .orElseThrow(() -> new NotFoundException("Group not found: " + groupId));
        Role role = roleRepository.findById(roleId)
                .orElseThrow(() -> new NotFoundException("Role not found: " + roleId));
        group.addRole(role);
        groupRepository.save(group);
    }

    @Transactional
    public void unbindRole(Long groupId, Long roleId) {
        Group group = groupRepository.findById(groupId)
                .orElseThrow(() -> new NotFoundException("Group not found: " + groupId));
        Role role = roleRepository.findById(roleId)
                .orElseThrow(() -> new NotFoundException("Role not found: " + roleId));
        group.removeRole(role);
        groupRepository.save(group);
    }

    @Transactional(readOnly = true)
    public List<RoleChecked> getRolesForGroupChecked(Long groupId) {
        Group group = groupRepository.findById(groupId)
                .orElseThrow(() -> new NotFoundException("Group not found: " + groupId));
        Set<Long> bound = group.getRoles().stream().map(Role::getId).collect(Collectors.toSet());
        return roleRepository.findAll().stream()
                .map(r -> new RoleChecked(r.getId(), r.getName(), bound.contains(r.getId())))
                .toList();
    }

    public record RoleChecked(Long roleId, String name, boolean checked) {}
```

Add imports as needed: `com.co.eurekatic.common.entity.Role`, `com.co.eurekatic.common.repository.RoleRepository`, `com.co.eurekatic.ssoadmin.exception.NotFoundException`, `java.util.List`, `java.util.Set`, `java.util.stream.Collectors`, `org.springframework.transaction.annotation.Transactional`.

- [ ] **Step 4: Run the service test to verify it passes**

Run: `docker run --rm -v "$(pwd -W):/w" -w /w -v sso-maven-repo:/root/.m2 maven:3.9-eclipse-temurin-25 mvn -B -ntp -pl sso-admin -am test -Dtest=GroupAdminServiceRolesTest`
Expected: PASS.

- [ ] **Step 5: Add the controller endpoints**

In `GroupController` (mirror `AppController`'s role endpoints; add `@DeleteMapping`, `@PathVariable`, `ResponseEntity` imports if missing):

```java
    @PostMapping("/{id}/role/{roleId}")
    public ResponseEntity<Void> bindRole(@PathVariable Long id, @PathVariable Long roleId) {
        service.bindRole(id, roleId);
        return ResponseEntity.noContent().build();
    }

    @DeleteMapping("/{id}/role/{roleId}")
    public ResponseEntity<Void> unbindRole(@PathVariable Long id, @PathVariable Long roleId) {
        service.unbindRole(id, roleId);
        return ResponseEntity.noContent().build();
    }

    @GetMapping("/{id}/roles/checked")
    public List<GroupAdminService.RoleChecked> getRolesForGroupChecked(@PathVariable Long id) {
        return service.getRolesForGroupChecked(id);
    }
```

- [ ] **Step 6: Run the full sso-admin suite (regression)**

Run: `docker run --rm -v "$(pwd -W):/w" -w /w -v sso-maven-repo:/root/.m2 -v /var/run/docker.sock:/var/run/docker.sock maven:3.9-eclipse-temurin-25 mvn -B -ntp -pl sso-admin -am test`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add sso-admin/src/main/java/com/co/eurekatic/ssoadmin/
git commit -m "feat(sso-admin): group↔role binding endpoints"
```

---

## Task 7: admin-ui — group role API + hooks

**Files:**
- Modify: `admin-ui/src/api/endpoints.ts`
- Modify: `admin-ui/src/hooks/useGroups.ts`

- [ ] **Step 1: Add the endpoints**

In `endpoints.ts`, extend the groups API object (mirror the `appsApi.bindRole/unbindRole/getRolesChecked` block already in this file). `RoleChecked` is the same shape the App tab uses — reuse its type:

```ts
  bindRole: (id: number, roleId: number) =>
    apiClient.post<void>(`/sso-admin/group/${id}/role/${roleId}`),
  unbindRole: (id: number, roleId: number) =>
    apiClient.delete<void>(`/sso-admin/group/${id}/role/${roleId}`),
  getRolesChecked: (id: number) =>
    apiClient.get<RoleChecked[]>(`/sso-admin/group/${id}/roles/checked`),
```

- [ ] **Step 2: Add the hooks**

In `useGroups.ts`, mirror the `useApps.ts` role-binding hooks + query keys (`groupKeys.rolesChecked(id)`, a `useGroupRolesChecked(id)` query, and `useBindGroupRole`/`useUnbindGroupRole` mutations that invalidate `groupKeys.rolesChecked(id)` on success). Copy the App implementation and rename `appsApi` → `groupsApi`, `appKeys` → `groupKeys`.

- [ ] **Step 3: Typecheck**

Run: `cd admin-ui && npm run build`
Expected: no TypeScript errors.

- [ ] **Step 4: Commit**

```bash
git add admin-ui/src/api/endpoints.ts admin-ui/src/hooks/useGroups.ts
git commit -m "feat(admin-ui): group role binding API + hooks"
```

---

## Task 8: admin-ui — "Roles" tab in the group drawer

**Files:**
- Modify: `admin-ui/src/pages/groups/GroupFormDrawer.tsx`
- Test: `admin-ui/src/pages/groups/GroupFormDrawer.test.tsx`

- [ ] **Step 1: Write the failing test**

Mirror `AppFormDrawer`'s BindingTab test (copy `AppsListPage.test.tsx`/`AppFormDrawer` role-tab test setup — mock the group roles-checked query, render the drawer for an existing group, switch to the "Roles" tab, and assert a role checkbox toggles calling the bind hook):

```tsx
// Copy the render + MSW/mock-fetch harness the App drawer test uses.
it("toggling a role in the Roles tab calls bindRole", async () => {
  // render GroupFormDrawer for group id=1 with getRolesChecked -> [{roleId:9,name:"QUERY_READER",checked:false}]
  // click the "Roles" tab, click the QUERY_READER checkbox
  // expect the bindRole endpoint (POST /sso-admin/group/1/role/9) to have been called
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd admin-ui && npx vitest run src/pages/groups/GroupFormDrawer.test.tsx`
Expected: FAIL — no "Roles" tab in the drawer yet.

- [ ] **Step 3: Add the "Roles" tab**

In `GroupFormDrawer.tsx`, add a `BindingTab` for roles exactly as `AppFormDrawer.tsx` wires its Roles tab: use `useGroupRolesChecked(groupId)` for the data and `useBindGroupRole`/`useUnbindGroupRole` for the toggle. If the group drawer is currently single-pane (no tabs), introduce the shared `Tabs` component with two tabs — "General" (the existing name/description form) and "Roles" (the new BindingTab) — following `AppFormDrawer`'s tab structure.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd admin-ui && npx vitest run src/pages/groups/GroupFormDrawer.test.tsx`
Expected: PASS.

- [ ] **Step 5: Run the full admin-ui unit suite (regression)**

Run: `cd admin-ui && npx vitest run`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add admin-ui/src/pages/groups/GroupFormDrawer.tsx admin-ui/src/pages/groups/GroupFormDrawer.test.tsx
git commit -m "feat(admin-ui): Roles tab in the group drawer"
```

---

## Task 9: End-to-end manual verification

- [ ] **Step 1: Rebuild + run the affected services**

Run:
```bash
cd modernize && docker compose build auth-center sso-admin api-gateway && \
docker compose up -d flyway auth-center sso-admin api-gateway
```
Expected: Flyway applies V8 (or reports up-to-date); services become healthy.

- [ ] **Step 2: Drive the flow through the gateway**

- In the admin-ui (`localhost:8080/admin`): create a role `QUERY_READER`, create a group `ops`, open the group → Roles tab → bind `QUERY_READER`, then add a test user to the group (Users or bindUserGroup).
- Log in as that user; confirm the sidebar/menu shows the routes that `QUERY_READER` grants via `role_app` — proving the group role reached the JWT and drove access with zero gateway changes.

- [ ] **Step 3: Commit any doc updates**

```bash
git add -A && git commit -m "docs: note groups-as-role-bundles verified end-to-end" --allow-empty
```

---

## Notes for the implementer

- Build/test commands assume Git Bash on Windows with Docker (no local Maven/JDK 25). `$(pwd -W)` yields the Windows path Docker needs; prefix with `MSYS_NO_PATHCONV=1` if a path is mangled. Integration tests that use Testcontainers need `/var/run/docker.sock` mounted (shown in the commands above).
- The DB is Neon in `.env`; Flyway there is already at V7, so V8 applies cleanly on the next run. Task 1's local-postgres check is only to validate the SQL in isolation.
- Do NOT change `User.getAuthorities()` — Spring Security uses it for the authentication decision (direct roles). Group roles are a JWT-issuance concern only, owned by `EffectiveRolesResolver`.
