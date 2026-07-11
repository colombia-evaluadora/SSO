package com.co.eurekatic.ssoadmin.controller;

import com.co.eurekatic.ssoadmin.dto.RouteResponse;
import com.co.eurekatic.ssoadmin.service.MyMenuService;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * Consumer-facing menu endpoint. Returns the sidebar entries
 * (routes) the caller is allowed to see, computed from the
 * JWT roles + the {@code role_app} / {@code role_route}
 * join tables.
 *
 * <p>Mirrors the {@code /myQueries} pattern:
 * <ul>
 *   <li>Authentication is required (any logged-in user).</li>
 *   <li>Per-row authorization is enforced inside the service
 *       (the {@link MyMenuService#forCaller} union query), not
 *       via {@code hasRole} on the controller — even non-admin
 *       users with role bindings get a populated menu.</li>
 *   <li>Empty list is a 200, not a 403 — the endpoint answers
 *       "what can I see?" and "nothing" is a legitimate answer.</li>
 * </ul>
 *
 * <p>The frontend (admin-ui) can call this on every
 * navigation if it wants — the query is a single SELECT
 * with two EXISTS subqueries against indexed columns
 * ({@code role_app.id_role} and {@code role_route.role_id}).
 * Cache headers (ETag / Cache-Control) are intentionally
 * NOT set here — when the user gets a role-rebinding,
 * admin-ui refetches and sees the new menu.
 *
 * <p>Optional {@code ?app=<name>} query parameter scopes the
 * returned list to routes of a single
 * {@link com.co.eurekatic.common.entity.App}. The SPA bundles
 * {@code VITE_APP_NAME} at build time and forwards the value
 * here so each deployment only ever shows the sidebar of its
 * own app. Callers that omit the param (legacy clients, the
 * smoke tests, multi-tenant menu editors) get the union
 * across every app the caller's roles grant — back-compat
 * preserved exactly. Unknown / blank {@code app} values are
 * normalized in the service layer to {@code 200 + []}, again
 * per the "what can I see?" contract.
 */
@RestController
public class MyMenuController {

    private final MyMenuService service;

    public MyMenuController(MyMenuService service) {
        this.service = service;
    }

    @GetMapping("/myMenu")
    public List<RouteResponse> myMenu(
            @RequestParam(required = false) String app) {
        Authentication auth = SecurityContextHolder.getContext().getAuthentication();
        // Trim in the controller so the service's short-circuit
        // logic only needs to handle null + non-blank; saves
        // re-trimming inside the hot query path.
        String trimmed = app == null ? null : app.trim();
        return trimmed == null || trimmed.isEmpty()
                ? service.forCaller(auth)
                : service.forCaller(auth, trimmed);
    }
}