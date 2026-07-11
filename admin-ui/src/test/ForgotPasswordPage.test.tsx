import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { ForgotPasswordPage } from "@/auth/ForgotPasswordPage";

/**
 * Render helper. Step 1 of the forgot-password flow — mirrors
 * {@link ./ActivatePage.test.tsx} / {@link
 * ./RestorePasswordPage.test.tsx}'s shape, but this page never
 * reads a token from the URL (it's where the token gets minted).
 */
function renderForgot() {
  let result!: ReturnType<typeof render>;
  act(() => {
    result = render(
      <MemoryRouter initialEntries={["/admin/forgot-password"]}>
        <Routes>
          <Route path="/admin/forgot-password" element={<ForgotPasswordPage />} />
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

describe("ForgotPasswordPage", () => {
  let fetchSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("renders an email field and a submit button", () => {
    renderForgot();
    expect(screen.getByLabelText("Email")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /Enviar enlace/i }),
    ).toBeInTheDocument();
  });

  it("disables submit until an email is entered", () => {
    renderForgot();
    expect(
      screen.getByRole("button", { name: /Enviar enlace/i }),
    ).toBeDisabled();
  });

  it("GETs /sso-admin/forgotPassword and shows the generic confirmation", async () => {
    fetchSpy.mockResolvedValueOnce(new Response(null, { status: 200 }));

    renderForgot();
    const user = userEvent.setup();
    await user.type(screen.getByLabelText("Email"), "someone@example.com");
    await user.click(screen.getByRole("button", { name: /Enviar enlace/i }));

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(1));
    const [url, init] = fetchSpy.mock.calls[0]!;
    expect(url).toBe(
      "/api/sso-admin/forgotPassword?email=someone%40example.com",
    );
    expect(init).toEqual(expect.objectContaining({ method: "GET" }));
    expect(init.headers).not.toHaveProperty("Authorization");

    expect(await screen.findByRole("alert")).toHaveTextContent(
      /someone@example.com/,
    );
    expect(await screen.findByRole("alert")).toHaveTextContent(
      /si.*está registrado.*te enviamos un correo/i,
    );
  });

  it("shows the same generic confirmation even when the request fails (no email enumeration)", async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify({ code: "INTERNAL_ERROR", message: "boom", timestamp: "" }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      }),
    );

    renderForgot();
    const user = userEvent.setup();
    await user.type(screen.getByLabelText("Email"), "unknown@example.com");
    await user.click(screen.getByRole("button", { name: /Enviar enlace/i }));

    expect(await screen.findByRole("alert")).toHaveTextContent(
      /si.*está registrado.*te enviamos un correo/i,
    );
  });
});
