import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { RestorePasswordPage } from "@/auth/RestorePasswordPage";

/**
 * Render helper. Mirror of {@link
 * ./ActivatePage.test.tsx}. Restore-password is a password-
 * *update* flow (unlike activation, the user already exists and
 * already has a password) but the wire shape and client-side
 * validation are identical to activation.
 */
function renderRestore(initialEntry: string) {
  let result!: ReturnType<typeof render>;
  act(() => {
    result = render(
      <MemoryRouter initialEntries={[initialEntry]}>
        <Routes>
          <Route
            path="/admin/restore-password"
            element={<RestorePasswordPage />}
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

describe("RestorePasswordPage", () => {
  let fetchSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("renders an error when no token is present in the URL", () => {
    renderRestore("/admin/restore-password");
    expect(
      screen.getByText(/Falta el token de restauración/i),
    ).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: /Restaurar contraseña/i }),
    ).not.toBeInTheDocument();
  });

  it("renders the new-password form when the URL carries a token", () => {
    renderRestore("/admin/restore-password?token=tok-restore");
    expect(screen.getByLabelText("Nueva contraseña")).toBeInTheDocument();
    expect(screen.getByLabelText("Repetir contraseña")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /Restaurar contraseña/i }),
    ).toBeInTheDocument();
  });

  it("disables submit until password is ≥6 chars and matches the confirm", async () => {
    renderRestore("/admin/restore-password?token=tok-restore");
    const user = userEvent.setup();

    await user.type(screen.getByLabelText("Nueva contraseña"), "abc");
    await user.type(screen.getByLabelText("Repetir contraseña"), "xyz");

    expect(
      screen.getByText(/Debe tener al menos 6 caracteres/i),
    ).toBeInTheDocument();
    expect(
      screen.getByText(/Las contraseñas no coinciden/i),
    ).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /Restaurar contraseña/i }),
    ).toBeDisabled();
  });

  it("POSTs {token, password} to /sso-admin/restorePassword and shows the success view", async () => {
    // The controller returns ResponseEntity.ok().build() — a
    // genuinely empty 200 body, not "{}". handleResponse must
    // treat that as "no content" rather than calling resp.json()
    // on it (which throws "Unexpected end of JSON input").
    fetchSpy.mockResolvedValueOnce(
      new Response("", { status: 200, headers: { "Content-Type": "application/json" } }),
    );
    renderRestore("/admin/restore-password?token=tok-restore");

    const user = userEvent.setup();
    await user.type(screen.getByLabelText("Nueva contraseña"), "newpass1");
    await user.type(screen.getByLabelText("Repetir contraseña"), "newpass1");
    await user.click(
      screen.getByRole("button", { name: /Restaurar contraseña/i }),
    );

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(1));
    const [url, init] = fetchSpy.mock.calls[0]!;
    expect(url).toBe("/api/sso-admin/restorePassword");
    expect(init).toEqual(
      expect.objectContaining({
        method: "POST",
        credentials: "same-origin",
      }),
    );
    expect(init.body).toContain('"token":"tok-restore"');
    expect(init.body).toContain('"password":"newpass1"');
    expect(init.headers).not.toHaveProperty("Authorization");

    expect(
      await screen.findByText(/Tu contraseña ha sido actualizada/i),
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
    renderRestore("/admin/restore-password?token=tok-stale");

    const user = userEvent.setup();
    await user.type(screen.getByLabelText("Nueva contraseña"), "newpass1");
    await user.type(screen.getByLabelText("Repetir contraseña"), "newpass1");
    await user.click(
      screen.getByRole("button", { name: /Restaurar contraseña/i }),
    );

    expect(await screen.findByRole("alert")).toHaveTextContent(
      /Token inválido o ya consumido/i,
    );
  });
});
