import { createBrowserRouter, Navigate } from "react-router-dom";
import { ActivatePage } from "@/auth/ActivatePage";
import { AppLauncherPage } from "@/auth/AppLauncherPage";
import { ForgotPasswordPage } from "@/auth/ForgotPasswordPage";
import { LoginPage } from "@/auth/LoginPage";
import { RequireAuth } from "@/auth/RequireAuth";
import { RestorePasswordPage } from "@/auth/RestorePasswordPage";
import { App } from "@/App";
import { GroupsListPage } from "@/pages/groups/GroupsListPage";
import { MicroservicesListPage } from "@/pages/microservices/MicroservicesListPage";
import { QueriesAdminPage } from "@/pages/queries/QueriesAdminPage";
import { QueriesDynamicPage } from "@/pages/queries/QueriesDynamicPage";
import { EndpointsListPage } from "@/pages/endpoints/EndpointsListPage";
import { RoutesListPage } from "@/pages/routes/RoutesListPage";
import { RolesListPage } from "@/pages/roles/RolesListPage";
import { UsersListPage } from "@/pages/users/UsersListPage";
import { AppsListPage } from "@/pages/apps/AppsListPage";
import { WritesListPage } from "@/pages/writes/WritesListPage";

/**
 * Router. Public routes: /admin/login, /admin/forgot-password
 * (request a reset link — linked from LoginPage), /activate
 * (legacy top-level for already-sent emails), /admin/activate and
 * /admin/restore-password (the SPA-under-admin paths the email
 * links now point at). Everything else under /admin is gated
 * by {@link RequireAuth}. We use the data router so loaders
 * can be added later for prefetch.
 *
 * Note: in production, the api-gateway serves the SPA at /admin/**
 * and falls back to index.html for any unknown path. So the URL
 * stays /admin/users, /admin/roles, etc. The /admin/login,
 * /admin/forgot-password, /admin/activate and
 * /admin/restore-password public routes MUST be declared above
 * the gated /admin parent so the more specific paths win
 * matching before the auth gate runs.
 *
 * All of these live under /admin rather than at top-level on
 * purpose: api-gateway's GatewaySecurityConfig only permits
 * unauthenticated requests under "/", "/admin", "/admin/**", and
 * AdminUiGlobalFilter only serves the SPA under /admin/**. A
 * top-level path (a bare /login or /forgot-password) 401s on a
 * hard navigation (bookmark, typed URL, refresh) — the request
 * never reaches React Router at all; e.g. a static SCG route with
 * Path=/login forwards straight to auth-center's POST-only login
 * endpoint instead of serving the SPA.
 */
export const router = createBrowserRouter([
  { path: "/admin/login", element: <LoginPage /> },
  // Step 1 of the forgot-password flow: request the reset link.
  // Step 2 (/admin/restore-password) is where the emailed link
  // lands and the password actually changes.
  { path: "/admin/forgot-password", element: <ForgotPasswordPage /> },
  // Legacy top-level route — emails sent before this branch
  // landed link here. Kept for one cycle of backward compat;
  // to be deleted once the next batch of activation emails
  // has been issued pointing at /admin/activate.
  { path: "/activate", element: <ActivatePage /> },
  // New SPA-under-admin activation route — the URL the
  // activation email links point at. Hosts the password
  // form that POSTs {token, password} to
  // /sso-admin/activateAccount (see ActivatePage).
  { path: "/admin/activate", element: <ActivatePage /> },
  // New SPA-under-admin restore-password route. Hosts the
  // password form that POSTs {token, password} to
  // /sso-admin/restorePassword (see RestorePasswordPage).
  { path: "/admin/restore-password", element: <RestorePasswordPage /> },
  {
    path: "/admin",
    element: <RequireAuth />,
    children: [
      // Post-login app picker — protected (needs the JWT to call
      // /myApps), but standalone: no sidebar, not part of SSO-
      // ADMIN's own navigation. Not to be confused with "apps"
      // below (the Apps CRUD admin screen, inside <App>).
      { path: "select-app", element: <AppLauncherPage /> },
      {
        element: <App />,
        children: [
          { index: true, element: <Navigate to="users" replace /> },
          { path: "users", element: <UsersListPage /> },
          { path: "roles", element: <RolesListPage /> },
          { path: "groups", element: <GroupsListPage /> },
          { path: "microservices", element: <MicroservicesListPage /> },
          // Legacy path — the consumer-only "Queries Catalog" page
          // was merged into the admin page at /admin/query-catalog
          // (which now also executes). Redirect so old links/menus
          // still land somewhere sane.
          { path: "queries", element: <Navigate to="/admin/query-catalog" replace /> },
          { path: "query-catalog", element: <QueriesAdminPage /> },
          { path: "dynamic-crud", element: <QueriesDynamicPage /> },
          { path: "endpoints", element: <EndpointsListPage /> },
          { path: "routes", element: <RoutesListPage /> },
          { path: "apps", element: <AppsListPage /> },
          { path: "writes", element: <WritesListPage /> },
        ],
      },
    ],
  },
  { path: "/", element: <Navigate to="/admin" replace /> },
  { path: "*", element: <Navigate to="/admin" replace /> },
]);
