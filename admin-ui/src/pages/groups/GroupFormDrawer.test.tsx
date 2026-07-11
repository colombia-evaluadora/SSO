import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { GroupFormDrawer } from "./GroupFormDrawer";
import type { GroupRoleChecked } from "@/api/types";

/**
 * Tests for the Roles tab on the Group drawer, mirroring
 * AppFormDrawer's Roles-tab coverage in AppsListPage.test.tsx.
 * fetch is stubbed and dispatched by URL fragment.
 */

function renderDrawer() {
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
      <GroupFormDrawer
        open
        group={{ id: 1, name: "ops", description: "", memberCount: 0 }}
        onClose={() => {}}
        onSubmit={async () => {}}
      />
    </QueryClientProvider>,
  );
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

function buildFetchSpy(rolesForGroup1: GroupRoleChecked[]) {
  return vi.fn((url: string | URL | Request, init?: RequestInit) => {
    const u = typeof url === "string" ? url : url.toString();
    const method = (init?.method ?? "GET").toUpperCase();

    const rolesCheckedMatch = u.match(/\/sso-admin\/group\/(\d+)\/roles\/checked$/);
    if (method === "GET" && rolesCheckedMatch) {
      const id = Number(rolesCheckedMatch[1]);
      return Promise.resolve(jsonResponse(id === 1 ? rolesForGroup1 : []));
    }

    const roleToggleMatch = u.match(/\/sso-admin\/group\/(\d+)\/role\/(\d+)$/);
    if (roleToggleMatch) {
      return Promise.resolve(new Response(null, { status: 204 }));
    }

    return Promise.reject(new Error(`Unexpected fetch: ${method} ${u}`));
  });
}

describe("GroupFormDrawer Roles tab", () => {
  let fetchSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("toggling a role in the Roles tab binds it", async () => {
    const spy = buildFetchSpy([
      { roleId: 9, name: "QUERY_READER", checked: false },
    ]);
    vi.stubGlobal("fetch", spy);

    renderDrawer();

    await userEvent.click(screen.getByRole("tab", { name: /^Roles$/i }));

    expect(await screen.findByText("QUERY_READER")).toBeInTheDocument();

    await userEvent.click(screen.getByTestId("role-toggle-9"));

    await waitFor(() =>
      expect(findFetchCall(spy, "/sso-admin/group/1/role/9")).toBeDefined(),
    );
    expect(
      (findFetchCall(spy, "/sso-admin/group/1/role/9")![1] as RequestInit)
        .method,
    ).toBe("POST");
  });
});
