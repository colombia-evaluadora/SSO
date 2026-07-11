package com.co.eurekatic.ssoadmin.service;

import com.co.eurekatic.common.entity.Query;
import com.co.eurekatic.common.entity.Role;
import com.co.eurekatic.common.repository.QueryRepository;
import com.co.eurekatic.ssoadmin.dto.QueryDefinition;
import com.co.eurekatic.ssoadmin.service.UserLookupService.UserRolesView;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.security.access.AccessDeniedException;

import java.util.List;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Unit tests for {@link QueryCatalogService}.
 *
 * <p>The repositories are mocked — these tests don't touch a
 * database. The role-intersection auth logic is the focus:
 * admin sees everything, regular users see only what their roles
 * permit, and {@code publicEnd} queries are visible to everyone.
 *
 * <p>These tests exist for {@code GET /myQueries} (the new list
 * endpoint) and {@code resolve()} (regression — the same auth
 * logic now lives behind a shared helper).
 */
@ExtendWith(MockitoExtension.class)
class QueryCatalogServiceTest {

    @Mock QueryRepository queryRepo;
    @Mock UserLookupService userLookup;
    @InjectMocks QueryCatalogService service;

    private static final String ADMIN = "admin";
    private static final String USER1 = "user1";
    private static final String USER2 = "user2";
    private static final String ROLE_REPORTS = "REPORTS";
    private static final String ROLE_ANALYTICS = "ANALYTICS";

    private Query q1;
    private Query q2;
    private Query qPublic;

    @BeforeEach
    void setUp() {
        q1 = queryWithRole("uuid-1", "SELECT 1", ROLE_REPORTS, false);
        q2 = queryWithRole("uuid-2", "SELECT 2", ROLE_ANALYTICS, false);
        qPublic = queryWithRole("uuid-pub", "SELECT pub", null, true);
    }

    /* ====================== resolve() regression ====================== */

    @Test
    void resolveReturnsDefinitionForKnownQueryWithMatchingRole() {
        when(queryRepo.findByUuid("uuid-1")).thenReturn(Optional.of(q1));
        when(userLookup.rolesFor(USER1)).thenReturn(viewWith(ROLE_REPORTS));

        QueryDefinition def = service.resolve("uuid-1", USER1);

        assertThat(def.uuid()).isEqualTo("uuid-1");
        assertThat(def.query()).isEqualTo("SELECT 1");
    }

    @Test
    void resolveReturns403WhenUuidUnknown() {
        when(queryRepo.findByUuid("nope")).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.resolve("nope", USER1))
                .isInstanceOf(AccessDeniedException.class);
        verify(userLookup, never()).rolesFor(USER1);
    }

    @Test
    void resolveReturns403WhenUserHasNoMatchingRole() {
        when(queryRepo.findByUuid("uuid-1")).thenReturn(Optional.of(q1));
        when(userLookup.rolesFor(USER2)).thenReturn(viewWith(ROLE_ANALYTICS));

        assertThatThrownBy(() -> service.resolve("uuid-1", USER2))
                .isInstanceOf(AccessDeniedException.class);
    }

    @Test
    void resolveAllowsPublicEndWithoutRoleCheck() {
        when(queryRepo.findByUuid("uuid-pub")).thenReturn(Optional.of(qPublic));
        when(userLookup.rolesFor(USER2)).thenReturn(viewWith(ROLE_ANALYTICS));
        QueryDefinition def = service.resolve("uuid-pub", USER2);

        assertThat(def.uuid()).isEqualTo("uuid-pub");
        verify(userLookup).rolesFor(USER2);
    }

    @Test
    void resolveAllowsAdminWithoutRoleCheck() {
        when(queryRepo.findByUuid("uuid-1")).thenReturn(Optional.of(q1));
        when(userLookup.rolesFor(ADMIN)).thenReturn(viewWith("ADMIN"));

        QueryDefinition def = service.resolve("uuid-1", ADMIN);

        assertThat(def.uuid()).isEqualTo("uuid-1");
    }

    /* ====================== listForCaller ====================== */

    @Test
    void listForCallerAdminSeesEverything() {
        when(userLookup.rolesFor(ADMIN)).thenReturn(viewWith("ADMIN"));
        when(queryRepo.findAllByOrderByIdAsc()).thenReturn(List.of(q1, q2, qPublic));

        List<QueryDefinition> result = service.listForCaller(ADMIN, null);

        assertThat(result).extracting(QueryDefinition::uuid)
                .containsExactly("uuid-1", "uuid-2", "uuid-pub");
    }

    @Test
    void listForCallerUserWithOneMatchingRoleSeesOnlyMatching() {
        when(userLookup.rolesFor(USER1)).thenReturn(viewWith(ROLE_REPORTS));
        when(queryRepo.findAllByOrderByIdAsc()).thenReturn(List.of(q1, q2, qPublic));

        List<QueryDefinition> result = service.listForCaller(USER1, null);

        assertThat(result).extracting(QueryDefinition::uuid)
                .containsExactly("uuid-1", "uuid-pub");
    }

    @Test
    void listForCallerUserWithNoRolesSeesOnlyPublic() {
        when(userLookup.rolesFor(USER2)).thenReturn(viewWith(ROLE_ANALYTICS));
        when(queryRepo.findAllByOrderByIdAsc()).thenReturn(List.of(q1, q2, qPublic));

        List<QueryDefinition> result = service.listForCaller(USER2, null);

        assertThat(result).extracting(QueryDefinition::uuid)
                .containsExactly("uuid-2", "uuid-pub");
    }

    @Test
    void listForCallerUserWithNoRolesAtAllSeesOnlyPublic() {
        when(userLookup.rolesFor("nobody")).thenReturn(UserRolesView.EMPTY);
        when(queryRepo.findAllByOrderByIdAsc()).thenReturn(List.of(q1, q2, qPublic));

        List<QueryDefinition> result = service.listForCaller("nobody", null);

        assertThat(result).extracting(QueryDefinition::uuid)
                .containsExactly("uuid-pub");
    }

    @Test
    void listForCallerReturnsEmptyWhenNoMatch() {
        when(userLookup.rolesFor(USER1)).thenReturn(viewWith(ROLE_REPORTS));
        when(queryRepo.findAllByMicroservice_IdOrderByIdAsc(eq(999L)))
                .thenReturn(List.of());

        List<QueryDefinition> result = service.listForCaller(USER1, 999L);

        assertThat(result).isEmpty();
    }

    @Test
    void listForCallerUsesMicroserviceFilterWhenProvided() {
        when(userLookup.rolesFor(ADMIN)).thenReturn(viewWith("ADMIN"));
        when(queryRepo.findAllByMicroservice_IdOrderByIdAsc(7L))
                .thenReturn(List.of(q1));

        List<QueryDefinition> result = service.listForCaller(ADMIN, 7L);

        assertThat(result).extracting(QueryDefinition::uuid).containsExactly("uuid-1");
        verify(queryRepo, never()).findAllByOrderByIdAsc();
    }

    @Test
    void listForCallerFallsBackToAllWhenMicroserviceIdNull() {
        when(userLookup.rolesFor(ADMIN)).thenReturn(viewWith("ADMIN"));
        when(queryRepo.findAllByOrderByIdAsc()).thenReturn(List.of(q1, q2));

        service.listForCaller(ADMIN, null);

        verify(queryRepo).findAllByOrderByIdAsc();
    }

    @Test
    void listForCallerNonAdminWithMissingUsernameSeesNothing() {
        when(userLookup.rolesFor("ghost")).thenReturn(UserRolesView.EMPTY);
        when(queryRepo.findAllByOrderByIdAsc()).thenReturn(List.of(q1, q2, qPublic));

        List<QueryDefinition> result = service.listForCaller("ghost", null);

        assertThat(result).extracting(QueryDefinition::uuid).containsExactly("uuid-pub");
    }

    /* ====================== helpers ====================== */

    private static Query queryWithRole(String uuid, String sql, String roleName, boolean publicEnd) {
        Query q = new Query();
        q.setUuid(uuid);
        q.setQuery(sql);
        q.setPublicEnd(publicEnd);
        if (roleName != null) {
            Role r = new Role();
            r.setName(roleName);
            q.getRoles().add(r);
        }
        return q;
    }

    private static UserRolesView viewWith(String... roleNames) {
        return new UserRolesView(1L, "test@test.com", Set.of(roleNames));
    }
}