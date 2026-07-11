import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ToastProvider } from "@/components/ui/Toast";
import { AppsListPage } from "./AppsListPage";
import type {
  AppResponse,
  AppRoleChecked,
  AppRouteChecked,
} from "@/api/types";

/**
 * Tests for the Apps admin CRUD page. Same pattern as
 * {@code QueriesAdminPage.test.tsx}: fetch is stubbed via
 * {@code vi.stubGlobal("fetch", ...)} and dispatched by URL
 * fragment so TanStack Query's parallel-mount fetches don't
 * fight.
 *
 * <p>Coverage scope:
 * <ul>
 *   <li>Renders rows from {@code GET /app/getApps} with their
 *       4 binding badges.</li>
 *   <li>"+ Nueva app" opens the drawer; submitting POSTs to
 *       {@code /app/save}. Drawer closes.</li>
 *   <li>"Editar" opens the drawer with the row's data; submit
 *       PUTs to {@code /app/update}. Drawer stays open.</li>
 *   <li>The 4 binding tabs (Roles/Users/Routes/Microservices)
 *       each list checked rows from the
 *       {@code /<family>s/checked} endpoint and toggle with
 *       POST/DELETE on {@code /<family>/<id>}.</li>
 *   <li>A toggle refreshes the table badge count (the
 *       {@code list} query is invalidated).</li>
 *   <li>"Eliminar" opens the confirm modal; on confirm,
 *       {@code DELETE /app/{id}} fires.</li>
 *   <li>Empty state shows the configured copy.</li>
 * </ul>
 */

function renderPage() {
  const qc = new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 0,
        gcTime: 0,
        retry: false,
        refetchOnWindowFocus: false,
      },
      mutations: { retry: false },
    },
  });
  return render(
    <QueryClientProvider client={qc}>
      <ToastProvider>
        <MemoryRouter>
          <AppsListPage />
        </MemoryRouter>
      </ToastProvider>
    </QueryClientProvider>,
  );
}

function mkApp(over: Partial<AppResponse> = {}): AppResponse {
  return {
    id: 1,
    name: "cockpit",
    description: "Dashboard de operaciones",
    launchUrl: null,
    createdDate: "2026-06-01T00:00:00Z",
    roleIds: [10],
    userIds: [],
    routeIds: [100, 101],
    microserviceIds: [],
    ...over,
  };
}

function mkRoleChecked(r: Partial<AppRoleChecked>): AppRoleChecked {
  return { roleId: 1, name: "ADMIN", checked: false, ...r };
}
function mkRouteChecked(r: Partial<AppRouteChecked>): AppRouteChecked {
  return { routeId: 1, name: "home", path: "/home", checked: false, ...r };
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function findFetchCall(fetchSpy: ReturnType<typeof vi.fn>, urlFragment: string) {
  return fetchSpy.mock.calls.find(([url]) => {
    const u = typeof url === "string" ? url : (url as URL).toString();
    return u.includes(urlFragment);
  });
}

/**
 * Builds a fetch spy keyed by URL fragment. Parallel-mount
 * fetches (e.g. the roles-checked + routes-checked both
 * firing when the drawer opens on edit) hit the same mock
 * and dispatch by regex. Users/Microservices checked lists
 * use the same regex dispatch but are not exercised by the
 * current tests.
 */
function buildFetchSpy(opts: {
  apps: AppResponse[];
  rolesForId?: Record<number, AppRoleChecked[]>;
  routesForId?: Record<number, AppRouteChecked[]>;
}) {
  const fetchSpy = vi.fn(
    (url: string | URL | Request, init?: RequestInit) => {
      const u = typeof url === "string" ? url : url.toString();
      const method = (init?.method ?? "GET").toUpperCase();

      // ----- list -----
      if (method === "GET" && u.includes("/sso-admin/app/getApps")) {
        return Promise.resolve(jsonResponse(opts.apps));
      }
      // ----- create / update echo -----
      if (method === "POST" && u.includes("/sso-admin/app/save")) {
        const body = JSON.parse((init?.body as string) ?? "{}");
        return Promise.resolve(
          jsonResponse({
            id: 999,
            name: body.name,
            description: body.description ?? null,
            createdDate: "2026-07-01T00:00:00Z",
            roleIds: [],
            userIds: [],
            routeIds: [],
            microserviceIds: [],
            ...body,
          }),
        );
      }
      if (method === "PUT" && u.includes("/sso-admin/app/update")) {
        const body = JSON.parse((init?.body as string) ?? "{}");
        return Promise.resolve(jsonResponse(body));
      }
      if (method === "DELETE" && /\/sso-admin\/app\/\d+$/.test(u)) {
        return Promise.resolve(new Response(null, { status: 204 }));
      }

      // ----- role toggles + checked -----
      const roleToggleMatch = u.match(/\/sso-admin\/app\/(\d+)\/role\/(\d+)$/);
      if (roleToggleMatch) {
        return Promise.resolve(new Response(null, { status: 204 }));
      }
      const roleCheckedMatch = u.match(
        /\/sso-admin\/app\/(\d+)\/roles\/checked$/,
      );
      if (method === "GET" && roleCheckedMatch) {
        const id = Number(roleCheckedMatch[1]);
        return Promise.resolve(
          jsonResponse(opts.rolesForId?.[id] ?? []),
        );
      }

      // ----- user toggles + checked (usersForId not yet in opts) -----
      const userToggleMatch = u.match(/\/sso-admin\/app\/(\d+)\/user\/(\d+)$/);
      if (userToggleMatch) {
        return Promise.resolve(new Response(null, { status: 204 }));
      }
      if (
        method === "GET" &&
        /\/sso-admin\/app\/(\d+)\/users\/checked$/.test(u)
      ) {
        return Promise.resolve(jsonResponse([]));
      }

      // ----- route toggles + checked -----
      const routeToggleMatch = u.match(/\/sso-admin\/app\/(\d+)\/route\/(\d+)$/);
      if (routeToggleMatch) {
        return Promise.resolve(new Response(null, { status: 204 }));
      }
      const routeCheckedMatch = u.match(
        /\/sso-admin\/app\/(\d+)\/routes\/checked$/,
      );
      if (method === "GET" && routeCheckedMatch) {
        const id = Number(routeCheckedMatch[1]);
        return Promise.resolve(
          jsonResponse(opts.routesForId?.[id] ?? []),
        );
      }

      // ----- microservice toggles + checked (microservicesForId not yet in opts) -----
      const msToggleMatch = u.match(
        /\/sso-admin\/app\/(\d+)\/microservice\/(\d+)$/,
      );
      if (msToggleMatch) {
        return Promise.resolve(new Response(null, { status: 204 }));
      }
      if (
        method === "GET" &&
        /\/sso-admin\/app\/(\d+)\/microservices\/checked$/.test(u)
      ) {
        return Promise.resolve(jsonResponse([]));
      }

      return Promise.reject(new Error(`Unexpected fetch: ${method} ${u}`));
    },
  );
  return fetchSpy;
}

describe("AppsListPage", () => {
  let fetchSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("renders rows from /getApps with binding badges", async () => {
    const a1 = mkApp({ id: 1, name: "cockpit", roleIds: [10, 11] });
    const a2 = mkApp({ id: 2, name: "reports", roleIds: [], routeIds: [] });
    const spy = buildFetchSpy({ apps: [a1, a2] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    expect(await screen.findByText("cockpit")).toBeInTheDocument();
    expect(screen.getByText("reports")).toBeInTheDocument();
    // binding badges (Roles · N, etc.) — React renders
    // template-literal text nodes as two siblings, so use regex
    expect(screen.getByText(/Roles · 2/)).toBeInTheDocument();
    expect(screen.getByText(/Roles · 0/)).toBeInTheDocument();
    // actions
    expect(screen.getByTestId("edit-1")).toBeInTheDocument();
    expect(screen.getByTestId("delete-1")).toBeInTheDocument();
    expect(screen.getByTestId("new-app")).toBeInTheDocument();
  });

  it("submitting the new-app drawer POSTs to /app/save and closes", async () => {
    const spy = buildFetchSpy({ apps: [] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("new-app"));

    const nameInput = screen.getByLabelText(/Nombre/i);
    await userEvent.type(nameInput, "MiApp");
    const descInput = screen.getByLabelText(/Descripción/i);
    await userEvent.type(descInput, "una app de prueba");

    await userEvent.click(screen.getByRole("button", { name: /^Crear$/i }));

    await waitFor(() =>
      expect(findFetchCall(spy, "/sso-admin/app/save")).toBeDefined(),
    );
    const call = findFetchCall(spy, "/sso-admin/app/save")!;
    expect((call[1] as RequestInit).method).toBe("POST");
    const body = JSON.parse((call[1] as RequestInit).body as string);
    expect(body.name).toBe("MiApp");
    expect(body.description).toBe("una app de prueba");

    // drawer closes on create
    await waitFor(() =>
      expect(screen.queryByLabelText(/Nombre/i)).not.toBeInTheDocument(),
    );
  });

  it("editing submits to /app/update and keeps the drawer open", async () => {
    const a1 = mkApp({ id: 1, name: "cockpit" });
    const spy = buildFetchSpy({ apps: [a1] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("edit-1"));

    // drawer opened with prefilled name
    const nameInput = await screen.findByLabelText(/Nombre/i);
    await userEvent.clear(nameInput);
    await userEvent.type(nameInput, "cockpit-v2");

    await userEvent.click(
      screen.getByRole("button", { name: /Guardar cambios/i }),
    );

    await waitFor(() =>
      expect(findFetchCall(spy, "/sso-admin/app/update")).toBeDefined(),
    );
    const call = findFetchCall(spy, "/sso-admin/app/update")!;
    expect((call[1] as RequestInit).method).toBe("PUT");
    const body = JSON.parse((call[1] as RequestInit).body as string);
    expect(body.id).toBe(1);
    expect(body.name).toBe("cockpit-v2");

    // drawer stays open in edit mode
    expect(screen.getByLabelText(/Nombre/i)).toBeInTheDocument();
  });

  it("Roles tab: toggling Vincular fires POST, Desvincular fires DELETE", async () => {
    const a1 = mkApp({ id: 1, name: "cockpit" });
    const roles: AppRoleChecked[] = [
      mkRoleChecked({ roleId: 10, name: "ADMIN", checked: true }),
      mkRoleChecked({ roleId: 20, name: "USER", checked: false }),
    ];
    const spy = buildFetchSpy({ apps: [a1], rolesForId: { 1: roles } });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("edit-1"));
    // switch to Roles tab
    await userEvent.click(screen.getByRole("tab", { name: /^Roles$/i }));

    expect(await screen.findByText("ADMIN")).toBeInTheDocument();
    expect(screen.getByText("USER")).toBeInTheDocument();
    expect(screen.getByTestId("role-toggle-10")).toHaveTextContent(
      /Desvincular/i,
    );
    expect(screen.getByTestId("role-toggle-20")).toHaveTextContent(
      /Vincular/i,
    );

    // bind USER (id=20)
    await userEvent.click(screen.getByTestId("role-toggle-20"));
    await waitFor(() =>
      expect(
        findFetchCall(spy, "/sso-admin/app/1/role/20"),
      ).toBeDefined(),
    );
    expect(
      (findFetchCall(spy, "/sso-admin/app/1/role/20")![1] as RequestInit)
        .method,
    ).toBe("POST");

    // unbind ADMIN (id=10)
    await userEvent.click(screen.getByTestId("role-toggle-10"));
    await waitFor(() =>
      expect(
        findFetchCall(spy, "/sso-admin/app/1/role/10"),
      ).toBeDefined(),
    );
    expect(
      (findFetchCall(spy, "/sso-admin/app/1/role/10")![1] as RequestInit)
        .method,
    ).toBe("DELETE");
  });

  it("Routes tab: toggle works identically", async () => {
    const a1 = mkApp({ id: 1, name: "cockpit" });
    const routes: AppRouteChecked[] = [
      mkRouteChecked({
        routeId: 100,
        name: "home",
        path: "/home",
        checked: false,
      }),
    ];
    const spy = buildFetchSpy({ apps: [a1], routesForId: { 1: routes } });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("edit-1"));
    await userEvent.click(screen.getByRole("tab", { name: /^Rutas$/i }));

    expect(await screen.findByText("home")).toBeInTheDocument();
    // path shown as secondary text
    expect(screen.getByText("/home")).toBeInTheDocument();
    // toggle bind
    await userEvent.click(screen.getByTestId("route-toggle-100"));
    await waitFor(() =>
      expect(
        findFetchCall(spy, "/sso-admin/app/1/route/100"),
      ).toBeDefined(),
    );
    expect(
      (findFetchCall(spy, "/sso-admin/app/1/route/100")![1] as RequestInit)
        .method,
    ).toBe("POST");
  });

  it("toggling a binding re-fetches /getApps so the badge counts refresh", async () => {
    const a1 = mkApp({ id: 1, name: "cockpit", roleIds: [] });
    const roles: AppRoleChecked[] = [
      mkRoleChecked({ roleId: 20, name: "USER", checked: false }),
    ];
    const spy = buildFetchSpy({ apps: [a1], rolesForId: { 1: roles } });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("edit-1"));
    await userEvent.click(screen.getByRole("tab", { name: /^Roles$/i }));

    // before toggle: count was 0 (regex: template-literal split)
    expect(screen.getByText(/Roles · 0/)).toBeInTheDocument();

    await userEvent.click(await screen.findByTestId("role-toggle-20"));

    // bind + invalidate list → at least 2 GETs to /getApps
    await waitFor(() =>
      expect(
        spy.mock.calls.filter(([url]) =>
          (typeof url === "string" ? url : url.toString()).includes(
            "/sso-admin/app/getApps",
          ),
        ).length,
      ).toBeGreaterThanOrEqual(2),
    );
  });

  it("deleting opens the confirm modal and on confirm fires DELETE /app/{id}", async () => {
    const a1 = mkApp({ id: 33, name: "doomed" });
    const spy = buildFetchSpy({ apps: [a1] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("delete-33"));

    const dialog = await screen.findByRole("dialog", { name: /Eliminar app/i });
    expect(dialog).toBeInTheDocument();

    await userEvent.click(
      within(dialog).getByTestId("app-confirm-delete"),
    );

    await waitFor(() =>
      expect(findFetchCall(spy, "/sso-admin/app/33")).toBeDefined(),
    );
    const call = findFetchCall(spy, "/sso-admin/app/33")!;
    expect((call[1] as RequestInit).method).toBe("DELETE");
  });

  it("shows the empty-state copy when there are no apps", async () => {
    const spy = buildFetchSpy({ apps: [] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    expect(
      await screen.findByText("Aún no hay apps."),
    ).toBeInTheDocument();
  });

  it("binding tabs are disabled (with hint) in create mode", async () => {
    const spy = buildFetchSpy({ apps: [] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("new-app"));
    // The drawer is on the General tab by default. Click Roles:
    await userEvent.click(screen.getByRole("tab", { name: /^Roles$/i }));
    expect(
      screen.getByText(
        /Guarda la app primero para habilitar la gestión de vinculaciones/i,
      ),
    ).toBeInTheDocument();
  });
});