import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ToastProvider } from "@/components/ui/Toast";
import { RoutesListPage } from "./RoutesListPage";
import type { RouteResponse, RouteRoleChecked } from "@/api/types";

/**
 * Tests for the Routes admin CRUD page, focused on the Roles
 * binding tab added to {@code RouteFormDrawer} (role_route —
 * previously manageable only by direct SQL/migration, per its own
 * "se asignan en otra pantalla" placeholder text). Same
 * fetch-stub-by-URL-fragment pattern as {@code AppsListPage.test.tsx}.
 */

function renderPage() {
  const qc = new QueryClient({
    defaultOptions: {
      queries: { staleTime: 0, gcTime: 0, retry: false, refetchOnWindowFocus: false },
      mutations: { retry: false },
    },
  });
  return render(
    <QueryClientProvider client={qc}>
      <ToastProvider>
        <MemoryRouter>
          <RoutesListPage />
        </MemoryRouter>
      </ToastProvider>
    </QueryClientProvider>,
  );
}

function mkRoute(over: Partial<RouteResponse> = {}): RouteResponse {
  return {
    id: 1,
    name: "Usuarios",
    icon: "users",
    path: "/admin/users",
    menuOrder: 1,
    type: "MENU",
    idParent: null,
    roleIds: [],
    ...over,
  };
}

function mkRoleChecked(r: Partial<RouteRoleChecked>): RouteRoleChecked {
  return { roleId: 1, name: "ADMIN", checked: false, ...r };
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function buildFetchSpy(opts: {
  routes: RouteResponse[];
  rolesForId?: Record<number, RouteRoleChecked[]>;
}) {
  return vi.fn((url: string | URL | Request, init?: RequestInit) => {
    const u = typeof url === "string" ? url : url.toString();
    const method = (init?.method ?? "GET").toUpperCase();

    if (method === "GET" && u.includes("/sso-admin/route/getRoutes")) {
      return Promise.resolve(jsonResponse(opts.routes));
    }
    if (method === "PUT" && u.includes("/sso-admin/route/update")) {
      const body = JSON.parse((init?.body as string) ?? "{}");
      return Promise.resolve(jsonResponse(body));
    }
    if (method === "DELETE" && /\/sso-admin\/route\/\d+$/.test(u)) {
      return Promise.resolve(new Response(null, { status: 204 }));
    }

    const roleToggleMatch = u.match(/\/sso-admin\/route\/(\d+)\/role\/(\d+)$/);
    if (roleToggleMatch) {
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    const roleCheckedMatch = u.match(/\/sso-admin\/route\/(\d+)\/roles\/checked$/);
    if (method === "GET" && roleCheckedMatch) {
      const id = Number(roleCheckedMatch[1]);
      return Promise.resolve(jsonResponse(opts.rolesForId?.[id] ?? []));
    }

    return Promise.reject(new Error(`Unexpected fetch: ${method} ${u}`));
  });
}

describe("RoutesListPage", () => {
  let fetchSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("renders rows from /route/getRoutes", async () => {
    const spy = buildFetchSpy({ routes: [mkRoute()] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    expect(await screen.findByText("Usuarios")).toBeInTheDocument();
    expect(screen.getByText("/admin/users")).toBeInTheDocument();
  });

  it("search box filters rows by name or path (case-insensitive), clear restores the list", async () => {
    const spy = buildFetchSpy({
      routes: [
        mkRoute({ id: 1, name: "Usuarios", path: "/admin/users" }),
        mkRoute({ id: 2, name: "Roles", path: "/admin/roles" }),
        mkRoute({ id: 3, name: "Grupos", path: "/admin/groups" }),
      ],
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await screen.findByText("Usuarios");
    expect(screen.getByText("Roles")).toBeInTheDocument();
    expect(screen.getByText("Grupos")).toBeInTheDocument();

    const search = screen.getByTestId("search-input");

    // Match by name, case-insensitive.
    await userEvent.type(search, "rol");
    expect(screen.getByText("Roles")).toBeInTheDocument();
    expect(screen.queryByText("Usuarios")).not.toBeInTheDocument();
    expect(screen.queryByText("Grupos")).not.toBeInTheDocument();

    // Match by path instead of name.
    await userEvent.clear(search);
    await userEvent.type(search, "/admin/groups");
    expect(screen.getByText("Grupos")).toBeInTheDocument();
    expect(screen.queryByText("Roles")).not.toBeInTheDocument();

    // No match -> empty state, not the "no rows at all" message.
    await userEvent.clear(search);
    await userEvent.type(search, "nonexistent");
    expect(await screen.findByText("Sin resultados.")).toBeInTheDocument();

    // Clear button restores the full list.
    await userEvent.click(screen.getByLabelText(/Limpiar búsqueda/i));
    expect(await screen.findByText("Usuarios")).toBeInTheDocument();
    expect(screen.getByText("Roles")).toBeInTheDocument();
    expect(screen.getByText("Grupos")).toBeInTheDocument();
  });

  it("binding tab is disabled (with hint) in create mode", async () => {
    const spy = buildFetchSpy({ routes: [] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("new-route"));
    await userEvent.click(screen.getByRole("tab", { name: /Roles/i }));

    expect(
      screen.getByText(/Guarda la ruta primero/i),
    ).toBeInTheDocument();
  });

  it("Roles tab: toggling Vincular fires POST, Desvincular fires DELETE", async () => {
    const route = mkRoute({ id: 5 });
    const spy = buildFetchSpy({
      routes: [route],
      rolesForId: {
        5: [
          mkRoleChecked({ roleId: 10, name: "ADMIN", checked: true }),
          mkRoleChecked({ roleId: 20, name: "USER", checked: false }),
        ],
      },
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("edit-5"));
    await userEvent.click(screen.getByRole("tab", { name: /Roles/i }));

    expect(await screen.findByTestId("role-toggle-10")).toHaveTextContent(
      /Desvincular/i,
    );
    expect(screen.getByTestId("role-toggle-20")).toHaveTextContent(
      /Vincular/i,
    );

    // USER (unchecked) -> bind -> POST
    await userEvent.click(screen.getByTestId("role-toggle-20"));
    await waitFor(() =>
      expect(
        spy.mock.calls.some(([url, init]) => {
          const u = typeof url === "string" ? url : (url as URL).toString();
          return (
            u.endsWith("/sso-admin/route/5/role/20") &&
            (init?.method ?? "GET").toUpperCase() === "POST"
          );
        }),
      ).toBe(true),
    );

    // ADMIN (checked) -> unbind -> DELETE
    await userEvent.click(screen.getByTestId("role-toggle-10"));
    await waitFor(() =>
      expect(
        spy.mock.calls.some(([url, init]) => {
          const u = typeof url === "string" ? url : (url as URL).toString();
          return (
            u.endsWith("/sso-admin/route/5/role/10") &&
            (init?.method ?? "GET").toUpperCase() === "DELETE"
          );
        }),
      ).toBe(true),
    );
  });
});
