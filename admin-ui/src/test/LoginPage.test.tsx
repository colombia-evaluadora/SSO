import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { AuthProvider } from "@/auth/AuthProvider";
import { LoginPage } from "@/auth/LoginPage";

/**
 * Renders the LoginPage inside MemoryRouter + AuthProvider. The
 * AuthProvider will fire a silent /api/auth/refresh on mount; we
 * stub fetch to return 401 for that, so the user lands in
 * "unauthenticated" and the form is interactive.
 *
 * <p>Post-V12 the login identifier is the user's email (the
 * legacy {@code username} column is gone), so the form labels
 * reflect that — the password manager hint is
 * {@code autoComplete="email"} and the visible label says
 * "Email".
 */
function renderLogin(
  initialEntry: string | { pathname: string; state?: unknown } = "/admin/login",
) {
  let result!: ReturnType<typeof render>;
  act(() => {
    result = render(
      <MemoryRouter initialEntries={[initialEntry]}>
        <AuthProvider>
          <Routes>
            <Route path="/admin/login" element={<LoginPage />} />
            <Route path="/admin" element={<div data-testid="admin-landing">admin</div>} />
            <Route path="/admin/roles" element={<div data-testid="roles-landing">roles</div>} />
            <Route
              path="/admin/select-app"
              element={<div data-testid="select-app-landing">select-app</div>}
            />
          </Routes>
        </AuthProvider>
      </MemoryRouter>,
    );
  });
  return result;
}

describe("LoginPage", () => {
  let fetchSpy: ReturnType<typeof vi.fn>;
  beforeEach(() => {
    fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("renders email, password and a submit button", async () => {
    fetchSpy.mockResolvedValueOnce(new Response("nope", { status: 401 })); // boot refresh
    renderLogin();
    expect(screen.getByLabelText(/Email/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/Contraseña/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Entrar/i })).toBeInTheDocument();
  });

  it("submits credentials and navigates on success", async () => {
    // boot refresh 401
    fetchSpy.mockResolvedValueOnce(new Response("nope", { status: 401 }));
    // login success
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify({ token: "t", refreshToken: "r", expiresIn: 600 }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
    // app-access check (AuthProvider.hasAccessToThisApp) — non-empty
    // menu means this role can use the app
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify([{ id: 1, name: "Usuarios", path: "/admin/users" }]), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );

    renderLogin("/admin/login");
    await waitFor(() => expect(fetchSpy).toHaveBeenCalled());

    const user = userEvent.setup();
    await user.type(screen.getByLabelText(/Email/i), "admin@example.com");
    await user.type(screen.getByLabelText(/Contraseña/i), "ChangeMe-Now-123");
    await user.click(screen.getByRole("button", { name: /Entrar/i }));

    expect(await screen.findByTestId("admin-landing")).toBeInTheDocument();
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/auth/login",
      expect.objectContaining({ method: "POST" }),
    );
  });

  it("rejects login with a clear message when the role has no access to this app", async () => {
    fetchSpy.mockResolvedValueOnce(new Response("nope", { status: 401 })); // boot
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify({ token: "t", refreshToken: "r", expiresIn: 600 }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    ); // login succeeds — credentials were valid
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify([]), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    ); // empty menu — this role has no role_app binding to this app
    fetchSpy.mockResolvedValueOnce(new Response(null, { status: 204 })); // logout cleanup

    renderLogin("/admin/login");
    await waitFor(() => expect(fetchSpy).toHaveBeenCalled());

    const user = userEvent.setup();
    await user.type(screen.getByLabelText(/Email/i), "no-access@example.com");
    await user.type(screen.getByLabelText(/Contraseña/i), "whatever123");
    await user.click(screen.getByRole("button", { name: /Entrar/i }));

    expect(await screen.findByRole("alert")).toHaveTextContent(
      /no tienes permiso para acceder a esta aplicación/i,
    );
    expect(screen.queryByTestId("admin-landing")).not.toBeInTheDocument();
  });

  it("redirects to the app picker when the caller has access to 2+ apps", async () => {
    fetchSpy.mockResolvedValueOnce(new Response("nope", { status: 401 })); // boot
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify({ token: "t", refreshToken: "r", expiresIn: 600 }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    ); // login succeeds
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify([{ id: 1, name: "Usuarios", path: "/admin/users" }]), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    ); // hasAccessToThisApp — non-empty menu
    fetchSpy.mockResolvedValueOnce(
      new Response(
        JSON.stringify([
          { id: 1, name: "SSO-ADMIN", description: "Consola", launchUrl: "/admin/" },
          { id: 2, name: "COLOMBIA-EVALUADORA", description: "CE", launchUrl: "https://x" },
        ]),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    ); // myApps — 2 apps

    renderLogin("/admin/login");
    await waitFor(() => expect(fetchSpy).toHaveBeenCalled());

    const user = userEvent.setup();
    await user.type(screen.getByLabelText(/Email/i), "admin@example.com");
    await user.type(screen.getByLabelText(/Contraseña/i), "ChangeMe-Now-123");
    await user.click(screen.getByRole("button", { name: /Entrar/i }));

    expect(await screen.findByTestId("select-app-landing")).toBeInTheDocument();
    expect(screen.queryByTestId("admin-landing")).not.toBeInTheDocument();
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/auth/myApps",
      expect.anything(),
    );
  });

  it("still shows the picker when RequireAuth's from is the generic /admin bounce, not a real deep link", async () => {
    // This is the realistic path: a fresh, unauthenticated visit to
    // "/" or bare "/admin" makes RequireAuth redirect to login with
    // state.from = "/admin" (location.pathname at intercept time) —
    // that's NOT a deep link, just the default entry, and must not
    // be treated as one (regression: it used to skip the picker
    // for every normal login, not just real deep links).
    fetchSpy.mockResolvedValueOnce(new Response("nope", { status: 401 })); // boot
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify({ token: "t", refreshToken: "r", expiresIn: 600 }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    ); // login succeeds
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify([{ id: 1, name: "Usuarios", path: "/admin/users" }]), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    ); // hasAccessToThisApp — non-empty menu
    fetchSpy.mockResolvedValueOnce(
      new Response(
        JSON.stringify([
          { id: 1, name: "SSO-ADMIN", description: "Consola", launchUrl: "/admin/" },
          { id: 2, name: "COLOMBIA-EVALUADORA", description: "CE", launchUrl: "https://x" },
        ]),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    ); // myApps — 2 apps

    renderLogin({ pathname: "/admin/login", state: { from: "/admin" } });
    await waitFor(() => expect(fetchSpy).toHaveBeenCalled());

    const user = userEvent.setup();
    await user.type(screen.getByLabelText(/Email/i), "admin@example.com");
    await user.type(screen.getByLabelText(/Contraseña/i), "ChangeMe-Now-123");
    await user.click(screen.getByRole("button", { name: /Entrar/i }));

    expect(await screen.findByTestId("select-app-landing")).toBeInTheDocument();
    expect(screen.queryByTestId("admin-landing")).not.toBeInTheDocument();
  });

  it("skips the picker and honors an explicit deep link, even with 2+ apps", async () => {
    fetchSpy.mockResolvedValueOnce(new Response("nope", { status: 401 })); // boot
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify({ token: "t", refreshToken: "r", expiresIn: 600 }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    ); // login succeeds
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify([{ id: 1, name: "Roles", path: "/admin/roles" }]), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    ); // hasAccessToThisApp — non-empty menu

    renderLogin({ pathname: "/admin/login", state: { from: "/admin/roles" } });
    await waitFor(() => expect(fetchSpy).toHaveBeenCalled());

    const user = userEvent.setup();
    await user.type(screen.getByLabelText(/Email/i), "admin@example.com");
    await user.type(screen.getByLabelText(/Contraseña/i), "ChangeMe-Now-123");
    await user.click(screen.getByRole("button", { name: /Entrar/i }));

    expect(await screen.findByTestId("roles-landing")).toBeInTheDocument();
    expect(screen.queryByTestId("select-app-landing")).not.toBeInTheDocument();
    // Deep link is a clear enough signal — myApps is never even called.
    expect(fetchSpy).not.toHaveBeenCalledWith(
      "/api/auth/myApps",
      expect.anything(),
    );
  });

  it("shows an error message on bad credentials", async () => {
    fetchSpy.mockResolvedValueOnce(new Response("nope", { status: 401 })); // boot
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify({ code: "BAD_CREDENTIALS", message: "Email o contraseña inválidos", timestamp: "" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      }),
    );

    renderLogin();
    await waitFor(() => expect(fetchSpy).toHaveBeenCalled());

    const user = userEvent.setup();
    await user.type(screen.getByLabelText(/Email/i), "admin@example.com");
    await user.type(screen.getByLabelText(/Contraseña/i), "wrong");
    await user.click(screen.getByRole("button", { name: /Entrar/i }));

    expect(await screen.findByRole("alert")).toHaveTextContent(
      /Email o contraseña inválidos/i,
    );
  });
});
