import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { AppLauncherPage } from "@/auth/AppLauncherPage";
import type { AppSummary } from "@/api/types";

vi.mock("@/env", () => ({
  env: { VITE_API_BASE: "/api", VITE_APP_NAME: "SSO-ADMIN" },
}));

const SSO_ADMIN: AppSummary = {
  id: 1,
  name: "SSO-ADMIN",
  description: "Consola de administración",
  launchUrl: "/admin/",
};
const COLOMBIA: AppSummary = {
  id: 2,
  name: "COLOMBIA-EVALUADORA",
  description: "Colombia Evaluadora",
  launchUrl: "https://cartagena.colombiaevaluadora.co/",
};
const NO_URL: AppSummary = {
  id: 3,
  name: "SIN-URL",
  description: null,
  launchUrl: null,
};

function renderLauncher(initialState?: { apps?: AppSummary[] }) {
  let result!: ReturnType<typeof render>;
  act(() => {
    result = render(
      <MemoryRouter
        initialEntries={[{ pathname: "/admin/select-app", state: initialState }]}
      >
        <Routes>
          <Route path="/admin/select-app" element={<AppLauncherPage />} />
          <Route
            path="/admin/users"
            element={<div data-testid="users-landing">users</div>}
          />
        </Routes>
      </MemoryRouter>,
    );
  });
  return result;
}

describe("AppLauncherPage", () => {
  let fetchSpy: ReturnType<typeof vi.fn>;
  const originalLocation = window.location;

  beforeEach(() => {
    fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
    Object.defineProperty(window, "location", {
      value: { ...originalLocation, href: "" },
      writable: true,
      configurable: true,
    });
  });
  afterEach(() => {
    vi.unstubAllGlobals();
    Object.defineProperty(window, "location", {
      value: originalLocation,
      writable: true,
      configurable: true,
    });
  });

  it("renders cards from location.state without fetching", async () => {
    renderLauncher({ apps: [SSO_ADMIN, COLOMBIA] });

    expect(await screen.findByText("SSO-ADMIN")).toBeInTheDocument();
    expect(screen.getByText("COLOMBIA-EVALUADORA")).toBeInTheDocument();
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("falls back to fetching /auth/myApps when there's no location.state", async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify([SSO_ADMIN, COLOMBIA]), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );

    renderLauncher();

    expect(await screen.findByText("SSO-ADMIN")).toBeInTheDocument();
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(1));
    expect(fetchSpy.mock.calls[0]![0]).toBe("/api/auth/myApps");
  });

  it("clicking the card matching VITE_APP_NAME navigates internally to /admin/users", async () => {
    renderLauncher({ apps: [SSO_ADMIN, COLOMBIA] });
    const user = userEvent.setup();

    await user.click(await screen.findByText("SSO-ADMIN"));

    expect(await screen.findByTestId("users-landing")).toBeInTheDocument();
    expect(window.location.href).toBe("");
  });

  it("clicking an external app sets window.location.href", async () => {
    renderLauncher({ apps: [SSO_ADMIN, COLOMBIA] });
    const user = userEvent.setup();

    await user.click(await screen.findByText("COLOMBIA-EVALUADORA"));

    expect(window.location.href).toBe("https://cartagena.colombiaevaluadora.co/");
    expect(screen.queryByTestId("users-landing")).not.toBeInTheDocument();
  });

  it("disables a non-self app with no launchUrl configured", async () => {
    renderLauncher({ apps: [SSO_ADMIN, NO_URL] });

    const card = (await screen.findByText("SIN-URL")).closest("button");
    expect(card).toBeDisabled();
    expect(screen.getByText("URL no configurada")).toBeInTheDocument();
  });

  it("shows a message when the caller has no apps at all", async () => {
    renderLauncher({ apps: [] });

    expect(
      await screen.findByText(/No tienes apps asignadas/i),
    ).toBeInTheDocument();
  });
});
