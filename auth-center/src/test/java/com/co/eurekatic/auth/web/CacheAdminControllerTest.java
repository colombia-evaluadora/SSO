package com.co.eurekatic.auth.web;

import com.co.eurekatic.auth.security.SessionCacheProperties;
import com.co.eurekatic.auth.security.UserRolesCacheInvalidator;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * Standalone MockMvc test for {@link CacheAdminController}. The
 * controller's contract is one method, three outcomes (401, 403,
 * 204) and a 400 for malformed emails — a slice test is faster
 * and clearer than booting the full Spring Security chain.
 */
@ExtendWith(MockitoExtension.class)
class CacheAdminControllerTest {

    @Mock UserRolesCacheInvalidator invalidator;

    SessionCacheProperties props;

    MockMvc mockMvc;

    private static final String SECRET = "shared-secret-value";

    @BeforeEach
    void setUp() {
        props = new SessionCacheProperties(
                3600L, "sso:session:user-roles", SECRET, true, 60L);
        CacheAdminController controller = new CacheAdminController(invalidator, props);
        mockMvc = MockMvcBuilders.standaloneSetup(controller).build();
    }

    @Test
    void rejectsMissingSecretHeaderWith401() throws Exception {
        mockMvc.perform(post("/internal/cache/user-roles/alice@example.com")
                        .contentType(MediaType.APPLICATION_JSON))
                .andExpect(status().isUnauthorized());
        verify(invalidator, never()).invalidate(org.mockito.ArgumentMatchers.anyString());
    }

    @Test
    void rejectsMismatchedSecretWith403() throws Exception {
        mockMvc.perform(post("/internal/cache/user-roles/alice@example.com")
                        .header(CacheAdminController.SECRET_HEADER, "wrong")
                        .contentType(MediaType.APPLICATION_JSON))
                .andExpect(status().isForbidden());
        verify(invalidator, never()).invalidate(org.mockito.ArgumentMatchers.anyString());
    }

    @Test
    void rejectsEmptySecretConfigWith403() throws Exception {
        // Controller is wired with an empty configured secret
        // (operator forgot to set SSO_SESSION_USER_ROLES_INVALIDATION_SECRET).
        // Any supplied header should be rejected.
        props = new SessionCacheProperties(
                3600L, "sso:session:user-roles", "", true, 60L);
        CacheAdminController controller = new CacheAdminController(invalidator, props);
        MockMvc isolatedMvc = MockMvcBuilders.standaloneSetup(controller).build();

        isolatedMvc.perform(post("/internal/cache/user-roles/alice@example.com")
                        .header(CacheAdminController.SECRET_HEADER, "anything")
                        .contentType(MediaType.APPLICATION_JSON))
                .andExpect(status().isForbidden());
    }

    @Test
    void acceptsCorrectSecretAndReturns204() throws Exception {
        mockMvc.perform(post("/internal/cache/user-roles/alice@example.com")
                        .header(CacheAdminController.SECRET_HEADER, SECRET)
                        .contentType(MediaType.APPLICATION_JSON))
                .andExpect(status().isNoContent());
        verify(invalidator, times(1)).invalidate(eq("alice@example.com"));
    }

    @Test
    void rejectsEmailWithoutAtSignWith400() throws Exception {
        mockMvc.perform(post("/internal/cache/user-roles/not-an-email")
                        .header(CacheAdminController.SECRET_HEADER, SECRET)
                        .contentType(MediaType.APPLICATION_JSON))
                .andExpect(status().isBadRequest());
        verify(invalidator, never()).invalidate(org.mockito.ArgumentMatchers.anyString());
    }
}