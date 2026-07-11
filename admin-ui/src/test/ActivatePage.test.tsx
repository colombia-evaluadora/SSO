import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { ActivatePage } from "@/auth/ActivatePage";

/**
 * Render helper. The page is intentionally public — there is no
 * AuthProvider on the path from email-link to a successful
 * activation. We only mount the routes ActivatePage navigates to
 * (the post-success link to /login) so the success view's anchor
 * has somewhere to land. No /admin gate here; the success view is
 * the only render-able destination after activation.
 */
function renderActivate(initialEntry: string) {
  let result!: ReturnType<typeof render>;
  act(() => {
    result = render(
      <MemoryRouter initialEntries={[initialEntry]}>
        <Routes>
          <Route path="/admin/activate" element={<ActivatePage />} />
          <Route
            path="/activate"
            element={<ActivatePage />}
          />
          <Route
            path="/admin/login"
            element={<div data-testid="login-landing">login</div>}
          />
        </Routes>
      </MemoryRouter>,
    );
  });
  return result;
}

describe("ActivatePage", () => {
  let fetchSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("renders an error when no token is present in the URL", () => {
    renderActivate("/admin/activate");
    expect(
      screen.getByText(/Falta el token de activación/i),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /Activar cuenta/i }),
    ).not.toBeInTheDocument();
  });

  it("renders the password form when the URL carries a token", () => {
    renderActivate("/admin/activate?token=abc123");

    // Two password inputs — main + confirm. The first one is the
    // actual password; "Repetir contraseña" is the client-side
    // match guard (NOT sent across the wire).
    expect(screen.getByLabelText("Contraseña")).toBeInTheDocument();
    expect(screen.getByLabelText("Repetir contraseña")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /Activar cuenta/i }),
    ).toBeInTheDocument();
  });

  it("disables submit until password is ≥6 chars and matches the confirm", async () => {
    renderActivate("/admin/activate?token=abc123");
    const user = userEvent.setup();

    await user.type(screen.getByLabelText("Contraseña"), "abc");
    await user.type(screen.getByLabelText("Repetir contraseña"), "xyz");

    expect(
      screen.getByText(/Debe tener al menos 6 caracteres/i),
    ).toBeInTheDocument();
    expect(
      screen.getByText(/Las contraseñas no coinciden/i),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /Activar cuenta/i }),
    ).toBeDisabled();
  });

  it("POSTs {token, password} to /sso-admin/activateAccount and shows the success view", async () => {
    // The controller returns ResponseEntity.ok().build() — a
    // genuinely empty 200 body, not "{}". handleResponse must
    // treat that as "no content" rather than calling resp.json()
    // on it (which throws "Unexpected end of JSON input").
    fetchSpy.mockResolvedValueOnce(
      new Response("", { status: 200, headers: { "Content-Type": "application/json" } }),
    );
    renderActivate("/admin/activate?token=abc123");

    const user = userEvent.setup();
    await user.type(screen.getByLabelText("Contraseña"), "newpass1");
    await user.type(screen.getByLabelText("Repetir contraseña"), "newpass1");
    await user.click(
      screen.getByRole("button", { name: /Activar cuenta/i }),
    );

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(1));
    const [url, init] = fetchSpy.mock.calls[0]!;
    expect(url).toBe("/api/sso-admin/activateAccount");
    expect(init).toEqual(
      expect.objectContaining({
        method: "POST",
        credentials: "same-origin",
      }),
    );
    // JSON body — token + password, never URL. Asserting
    // containment so a future re-ordering or extra whitespace
    // in JSON.stringify doesn't break the test.
    expect(init.body).toContain('"token":"abc123"');
    expect(init.body).toContain('"password":"newpass1"');
    // No Authorization header — skipAuth=true on the public
    // activation endpoint (a session-less user is clicking from
    // their email).
    expect(init.headers).not.toHaveProperty("Authorization");

    expect(
      await screen.findByText(/Tu cuenta ha sido activada/i),
    ).toBeInTheDocument();
  });

  it("renders the error view (with the server message) when POST fails", async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response(
        JSON.stringify({
          code: "TOKEN_NOT_FOUND",
          message: "Token inválido o ya consumido",
          timestamp: "",
        }),
        { status: 404, headers: { "Content-Type": "application/json" } },
      ),
    );
    renderActivate("/admin/activate?token=stale");

    const user = userEvent.setup();
    await user.type(screen.getByLabelText("Contraseña"), "newpass1");
    await user.type(screen.getByLabelText("Repetir contraseña"), "newpass1");
    await user.click(
      screen.getByRole("button", { name: /Activar cuenta/i }),
    );

    expect(await screen.findByRole("alert")).toHaveTextContent(
      /Token inválido o ya consumido/i,
    );
  });
});
