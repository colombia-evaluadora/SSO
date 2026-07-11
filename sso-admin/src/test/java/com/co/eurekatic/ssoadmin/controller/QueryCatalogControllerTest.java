package com.co.eurekatic.ssoadmin.controller;

import com.co.eurekatic.common.security.AuthPrincipal;
import com.co.eurekatic.ssoadmin.dto.QueryDefinition;
import com.co.eurekatic.ssoadmin.exception.GlobalExceptionHandler;
import com.co.eurekatic.ssoadmin.service.QueryCatalogService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.util.List;
import java.util.Set;

import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Focused controller test for {@code GET /myQueries}.
 *
 * <p>Uses {@link MockMvcBuilders#standaloneSetup} (no Spring
 * context, no security filter chain) so the test stays in the
 * millisecond range. The principal is injected into the
 * {@code SecurityContextHolder} by hand to match what the
 * {@code JwtAuthenticationFilter} would have done in production;
 * the controller's {@code currentUsername()} helper reads it back.
 *
 * <p>The service is mocked — these tests verify the controller's
 * <em>shape</em> (path, query-param parsing, principal extraction,
 * JSON serialization) without exercising the per-row auth logic,
 * which is covered separately by {@code QueryCatalogServiceTest}.
 */
class QueryCatalogControllerTest {

    private QueryCatalogService service;
    private MockMvc mvc;

    @BeforeEach
    void setUp() {
        service = mock(QueryCatalogService.class);
        mvc = MockMvcBuilders
                .standaloneSetup(new QueryCatalogController(service))
                .setControllerAdvice(new GlobalExceptionHandler())
                .build();
    }

    @AfterEach
    void clearSecurityContext() {
        SecurityContextHolder.clearContext();
    }

    /* ====================== GET /myQueries ====================== */

    @Test
    void myQueriesReturnsServiceResultAsJsonArray() throws Exception {
        authenticateAs("user1");
        when(service.listForCaller(eq("user1"), isNull()))
                .thenReturn(List.of(
                        new QueryDefinition(1L, "uuid-a", "SELECT 1", null,
                                false, false, null, null, null, null),
                        new QueryDefinition(2L, "uuid-b", "SELECT 2", null,
                                true, false, null, null, null, 7L)));

        mvc.perform(get("/myQueries"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[0].uuid").value("uuid-a"))
                .andExpect(jsonPath("$[0].idQuery").value(1))
                .andExpect(jsonPath("$[0].microserviceId").doesNotExist())
                .andExpect(jsonPath("$[1].uuid").value("uuid-b"))
                .andExpect(jsonPath("$[1].publicEnd").value(true))
                .andExpect(jsonPath("$[1].microserviceId").value(7));
    }

    @Test
    void myQueriesForwardsMicroserviceIdFilterToService() throws Exception {
        authenticateAs("admin");
        when(service.listForCaller("admin", 7L)).thenReturn(List.of());

        mvc.perform(get("/myQueries").param("microserviceId", "7"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$").isArray())
                .andExpect(jsonPath("$.length()").value(0));

        verify(service).listForCaller("admin", 7L);
    }

    @Test
    void myQueriesForwardsNullMicroserviceIdWhenAbsent() throws Exception {
        authenticateAs("user1");
        when(service.listForCaller("user1", null)).thenReturn(List.of());

        mvc.perform(get("/myQueries"))
                .andExpect(status().isOk());

        verify(service).listForCaller("user1", null);
    }

    @Test
    void myQueriesReturns200WithEmptyArrayWhenServiceHasNoMatches() throws Exception {
        // "what can I see?" → "nothing" is a 200, not a 403.
        authenticateAs("nobody");
        when(service.listForCaller("nobody", null)).thenReturn(List.of());

        mvc.perform(get("/myQueries"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$").isArray())
                .andExpect(jsonPath("$.length()").value(0));
    }

    @Test
    void getQueryStillWorks() throws Exception {
        // Regression: the catalog single-row endpoint is unchanged.
        authenticateAs("user1");
        when(service.resolve("uuid-1", "user1"))
                .thenReturn(new QueryDefinition(1L, "uuid-1", "SELECT 1", null,
                        false, false, null, null, null, 7L));

        mvc.perform(get("/getQuery").param("uuid", "uuid-1"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.uuid").value("uuid-1"))
                .andExpect(jsonPath("$.microserviceId").value(7));
    }

    @Test
    void myQueriesReturns403WhenNoPrincipalInContext() throws Exception {
        // SecurityContextHolder is empty (no auth filter ran in
        // this standalone setup). The controller's
        // currentUsername() helper must throw
        // AccessDeniedException so the Spring Security pipeline
        // can map it to 403 once the filter is in place.
        SecurityContextHolder.clearContext();

        mvc.perform(get("/myQueries"))
                .andExpect(status().isForbidden());

        verifyNoInteractions(service);
    }

    /* ====================== helpers ====================== */

    /** Mimics what {@code JwtAuthenticationFilter} would have
     *  placed in the context for an authenticated request. */
    private static void authenticateAs(String username) {
        AuthPrincipal principal = new AuthPrincipal(username, Set.of(), "access");
        UsernamePasswordAuthenticationToken auth = new UsernamePasswordAuthenticationToken(
                principal,
                null,
                List.of(new SimpleGrantedAuthority("ROLE_USER")));
        SecurityContextHolder.getContext().setAuthentication(auth);
    }
}