import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ToastProvider } from "@/components/ui/Toast";
import { WritesListPage } from "./WritesListPage";
import type {
  ColumnInfo,
  MicroserviceResponse,
  TableInfo,
  WriteDefinitionResponse,
  WriteRoleChecked,
} from "@/api/types";

/**
 * Tests for the Writes admin CRUD page. Same fetch-stub +
 * URL-dispatch pattern as {@code AppsListPage.test.tsx}.
 *
 * <p>Coverage scope (mirrors the Apps test set + chips +
 * microservice picker):
 * <ul>
 *   <li>Renders rows from {@code GET /write/getWrites} with the
 *       columns + roles badge + microservice binding badge.</li>
 *   <li>"+ Nuevo write" opens the drawer; submitting POSTs to
 *       {@code /write/save} with JSON-as-string columns and
 *       the explicit microserviceId=null ("global") on the
 *       wire. Drawer closes.</li>
 *   <li>"Editar" opens the drawer with the row's chip data;
 *       submit PUTs to {@code /write/update}. Drawer stays
 *       open.</li>
 *   <li>Chip add/remove round-trip inside the edit drawer
 *       (no fetch — the form state is what we're after).</li>
 *   <li>Roles tab lists {@code roleId}+{@code name}+{@code checked}
 *       rows and toggles with POST/DELETE on
 *       {@code /write/{id}/role/{roleId}}.</li>
 *   <li>"Eliminar" opens the confirm modal; on confirm,
 *       {@code DELETE /write/{id}} fires.</li>
 *   <li>Empty state shows the configured copy.</li>
 *   <li>Microservicio column resolves the FK id → instance via
 *       {@code /sso-admin/microservice/getMicroservices}.</li>
 *   <li>Picking a {@code kind=QUERY} microservice lights up
 *       the {@code TablePicker}; choosing a row autofills the
 *       {@code tableName} input and ends up in the POST body.</li>
 *   <li>Without picking a microservice, the {@code TablePicker}
 *       panel does NOT render (the form stays a manual
 *       {@code schema.table} editor).</li>
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
          <WritesListPage />
        </MemoryRouter>
      </ToastProvider>
    </QueryClientProvider>,
  );
}

function mkWrite(over: Partial<WriteDefinitionResponse> = {}): WriteDefinitionResponse {
  return {
    id: 1,
    uuid: "smoke-write-1",
    writeType: "INSERT",
    tableName: "public.users",
    columns: '["ID","NAME"]',
    keyColumns: null,
    createdDate: "2026-07-01T00:00:00Z",
    roleIds: [10],
    microserviceId: null,
    ...over,
  };
}

function mkRoleChecked(r: Partial<WriteRoleChecked>): WriteRoleChecked {
  return { roleId: 1, name: "ADMIN", checked: false, ...r };
}

/**
 * Minimal {@code MicroserviceResponse} factory. We only
 * fill the fields the writes page actually consumes:
 * {@code id}, {@code kind}, {@code instanceName},
 * {@code dialect}. The rest are stubbed to keep the test
 * fixture readable.
 */
function mkMicroservice(
  over: Partial<MicroserviceResponse> = {},
): MicroserviceResponse {
  return {
    id: 7,
    serviceId: "smoke-ms",
    description: "",
    requestUri: "",
    targetUriPath: "",
    targetUrlHost: "",
    targetUrlPort: "",
    createdDate: "2026-07-01T00:00:00Z",
    kind: "QUERY",
    dialect: "postgres",
    jdbcUrl: null,
    dbUsername: null,
    dbPassword: null,
    poolSize: 10,
    instanceName: "postgres",
    ...over,
  };
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
 * Builds a fetch spy keyed by URL fragment. Write endpoints
 * follow the apps-style URL layout:
 * <ul>
 *   <li>GET /sso-admin/write/getWrites — list</li>
 *   <li>POST /sso-admin/write/save — create (no id)</li>
 *   <li>PUT /sso-admin/write/update — update (id in body)</li>
 *   <li>DELETE /sso-admin/write/{id} — delete</li>
 *   <li>POST /sso-admin/write/{id}/role/{roleId} — bind role</li>
 *   <li>DELETE /sso-admin/write/{id}/role/{roleId} — unbind role</li>
 *   <li>GET /sso-admin/write/{id}/roles/checked — roles list</li>
 *   <li>GET /sso-admin/microservice/getMicroservices — for the
 *       microservice dropdown in the drawer + the
 *       Microservicio column on the list page</li>
 *   <li>GET /query-service-<instance>/tables?dialect=… — for
 *       the inline TablePicker; filtered by instance+dialect</li>
 *   <li>GET /query-service-<instance>/columns?dialect=…&schema=…&table=… —
 *       for the inline ColumnPicker; filtered by
 *       instance+schema+table</li>
 * </ul>
 */
function buildFetchSpy(opts: {
  writes: WriteDefinitionResponse[];
  rolesForId?: Record<number, WriteRoleChecked[]>;
  microservices?: MicroserviceResponse[];
  tablesByInstance?: Record<string, TableInfo[]>;
  columnsByTable?: Record<string, ColumnInfo[]>;
}) {
  const fetchSpy = vi.fn(
    (url: string | URL | Request, init?: RequestInit) => {
      const u = typeof url === "string" ? url : url.toString();
      const method = (init?.method ?? "GET").toUpperCase();

      // list
      if (method === "GET" && u.includes("/sso-admin/write/getWrites")) {
        return Promise.resolve(jsonResponse(opts.writes));
      }
      // create echo
      if (method === "POST" && u.includes("/sso-admin/write/save")) {
        const body = JSON.parse((init?.body as string) ?? "{}");
        return Promise.resolve(
          jsonResponse({
            id: 999,
            createdDate: "2026-07-01T00:00:00Z",
            roleIds: [],
            microserviceId: body.microserviceId ?? null,
            ...body,
          }),
        );
      }
      // update echo
      if (method === "PUT" && u.includes("/sso-admin/write/update")) {
        const body = JSON.parse((init?.body as string) ?? "{}");
        return Promise.resolve(jsonResponse(body));
      }
      // delete /write/{id}
      if (method === "DELETE" && /\/sso-admin\/write\/\d+$/.test(u)) {
        return Promise.resolve(new Response(null, { status: 204 }));
      }

      // role toggle + checked
      const roleToggleMatch = u.match(
        /\/sso-admin\/write\/(\d+)\/role\/(\d+)$/,
      );
      if (roleToggleMatch) {
        return Promise.resolve(new Response(null, { status: 204 }));
      }
      const roleCheckedMatch = u.match(
        /\/sso-admin\/write\/(\d+)\/roles\/checked$/,
      );
      if (method === "GET" && roleCheckedMatch) {
        const id = Number(roleCheckedMatch[1]);
        return Promise.resolve(jsonResponse(opts.rolesForId?.[id] ?? []));
      }

      // microservices list — drives both the drawer <select>
      // and the page-level microserviceId→{instanceName,dialect}
      // lookup. Default = empty list so the dropdown shows just
      // "Sin binding (global)".
      if (
        method === "GET" &&
        u.includes("/sso-admin/microservice/getMicroservices")
      ) {
        return Promise.resolve(jsonResponse(opts.microservices ?? []));
      }

      // query-service /tables — call from the TablePicker once
      // a kind=QUERY microservice is selected. Filter by both
      // instanceName and dialect so a multi-dialect static
      // deployment hits the right slice.
      const tableMatch = u.match(
        /\/query-service-([^/]+)\/tables\?dialect=([^&]+)/,
      );
      if (method === "GET" && tableMatch && tableMatch[1] && tableMatch[2]) {
        const instance = tableMatch[1];
        const dialect = decodeURIComponent(tableMatch[2]);
        const key = `${instance}::${dialect}`;
        return Promise.resolve(
          jsonResponse(opts.tablesByInstance?.[key] ?? []),
        );
      }

      // query-service /columns — call from the ColumnPicker
      // once a kind=QUERY microservice is selected AND the
      // admin typed a schema.table in Tabla. Filtered by
      // (instance, schema, table) so multi-schema deployments
      // (admin / audit / analytics) hit the right slice.
      const columnMatch = u.match(
        /\/query-service-([^/]+)\/columns\?.*schema=([^&]+).*table=([^&]+)/,
      );
      if (method === "GET" && columnMatch) {
        const instance = columnMatch[1];
        const schema =
          columnMatch[2] != null ? decodeURIComponent(columnMatch[2]) : "";
        const table =
          columnMatch[3] != null ? decodeURIComponent(columnMatch[3]) : "";
        if (instance && schema != null && table != null) {
          const key = `${instance}::${schema}::${table}`;
          return Promise.resolve(
            jsonResponse(opts.columnsByTable?.[key] ?? []),
          );
        }
      }

      return Promise.reject(new Error(`Unexpected fetch: ${method} ${u}`));
    },
  );
  return fetchSpy;
}

describe("WritesListPage", () => {
  let fetchSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("renders rows from /getWrites with columns + roles + microservice badges", async () => {
    const ms = mkMicroservice({ id: 7, instanceName: "postgres", dialect: "postgres" });
    const w1 = mkWrite({ id: 1, uuid: "smoke-write-1", roleIds: [10], microserviceId: 7 });
    const w2 = mkWrite({ id: 2, uuid: "smoke-write-2", roleIds: [], microserviceId: null });
    const spy = buildFetchSpy({
      writes: [w1, w2],
      microservices: [ms],
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    expect(await screen.findByText("smoke-write-1")).toBeInTheDocument();
    expect(screen.getByText("smoke-write-2")).toBeInTheDocument();
    // writeType badges render
    expect(screen.getAllByText("INSERT").length).toBeGreaterThanOrEqual(1);
    // roles counts — template literal → 2 text nodes, use regex
    expect(screen.getByText(/Roles · 1/)).toBeInTheDocument();
    expect(screen.getByText(/Roles · 0/)).toBeInTheDocument();
    // columns count (2) shows for both
    expect(screen.getAllByText(/^2/).length).toBeGreaterThanOrEqual(1);
    // microservice lookup → row 1 shows resolved instance name
    // (#7 · postgres), row 2 shows "Global" badge
    const msCell = await screen.findByTestId("microservice-1");
    expect(msCell).toHaveTextContent("#7");
    expect(msCell).toHaveTextContent("postgres");
    expect(screen.getByTestId("microservice-global-2")).toHaveTextContent("Global");
    // actions
    expect(screen.getByTestId("edit-1")).toBeInTheDocument();
    expect(screen.getByTestId("delete-1")).toBeInTheDocument();
    expect(screen.getByTestId("new-write")).toBeInTheDocument();
  });

  it("submitting the new-write drawer POSTs to /write/save with JSON columns and closes", async () => {
    const spy = buildFetchSpy({ writes: [] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("new-write"));

    await userEvent.type(screen.getByLabelText(/UUID/i), "smoke-write-new");
    await userEvent.type(screen.getByLabelText(/Tabla/i), "public.users");
    // The select fires onChange properly — leave default INSERT.
    await userEvent.type(
      screen.getByTestId("write-columns-input"),
      "ID{Enter}",
    );

    await userEvent.click(screen.getByRole("button", { name: /^Crear$/i }));

    await waitFor(() =>
      expect(findFetchCall(spy, "/sso-admin/write/save")).toBeDefined(),
    );
    const call = findFetchCall(spy, "/sso-admin/write/save")!;
    expect((call[1] as RequestInit).method).toBe("POST");
    const body = JSON.parse((call[1] as RequestInit).body as string);
    expect(body.uuid).toBe("smoke-write-new");
    expect(body.tableName).toBe("public.users");
    // columns JSON-as-string
    expect(body.columns).toBe('["ID"]');
    expect(body.keyColumns).toBeNull();
    // No microservice was selected → microserviceId must be
    // null on the wire so the backend's "global" path runs.
    expect(body.microserviceId).toBeNull();

    // drawer closes on create
    await waitFor(() =>
      expect(screen.queryByLabelText(/UUID/i)).not.toBeInTheDocument(),
    );
  });

  it("editing submits to /write/update and keeps the drawer open", async () => {
    const w1 = mkWrite({
      id: 1,
      uuid: "smoke-write-1",
      columns: '["ID","NAME"]',
    });
    const spy = buildFetchSpy({ writes: [w1] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("edit-1"));

    const tableInput = await screen.findByLabelText(/Tabla/i);
    await userEvent.clear(tableInput);
    await userEvent.type(tableInput, "public.orders_v2");

    await userEvent.click(
      screen.getByRole("button", { name: /Guardar cambios/i }),
    );

    await waitFor(() =>
      expect(findFetchCall(spy, "/sso-admin/write/update")).toBeDefined(),
    );
    const call = findFetchCall(spy, "/sso-admin/write/update")!;
    expect((call[1] as RequestInit).method).toBe("PUT");
    const body = JSON.parse((call[1] as RequestInit).body as string);
    expect(body.id).toBe(1);
    expect(body.tableName).toBe("public.orders_v2");
    // Existing chips render in the form state
    expect(body.columns).toBe('["ID","NAME"]');

    // drawer stays open in edit mode
    expect(screen.getByLabelText(/Tabla/i)).toBeInTheDocument();
  });

  it("chip add + remove inside the edit drawer (no fetch)", async () => {
    const w1 = mkWrite({
      id: 1,
      uuid: "smoke-write-1",
      columns: '["ID","NAME"]',
    });
    const spy = buildFetchSpy({ writes: [w1] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("edit-1"));

    // Existing chips render
    expect(screen.getByTestId("write-columns-chip-0")).toHaveTextContent("ID");
    expect(screen.getByTestId("write-columns-chip-1")).toHaveTextContent("NAME");

    // Add a third chip
    await userEvent.type(
      screen.getByTestId("write-columns-input"),
      "EMAIL{Enter}",
    );
    expect(screen.getByTestId("write-columns-chip-2")).toHaveTextContent(
      "EMAIL",
    );

    // Remove middle chip
    await userEvent.click(screen.getByTestId("write-columns-remove-1"));
    expect(screen.getByTestId("write-columns-chip-0")).toHaveTextContent("ID");
    expect(screen.getByTestId("write-columns-chip-1")).toHaveTextContent(
      "EMAIL",
    );
    // No fetch yet — chips are pure local form state
    expect(spy.mock.calls.length).toBeLessThan(5);
  });

  it("Roles tab: toggling Vincular fires POST, Desvincular fires DELETE", async () => {
    const w1 = mkWrite({ id: 1, uuid: "smoke-write-1" });
    const roles: WriteRoleChecked[] = [
      mkRoleChecked({ roleId: 10, name: "ADMIN", checked: true }),
      mkRoleChecked({ roleId: 20, name: "USER", checked: false }),
    ];
    const spy = buildFetchSpy({
      writes: [w1],
      rolesForId: { 1: roles },
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("edit-1"));
    await userEvent.click(screen.getByRole("tab", { name: /^Roles$/i }));

    expect(await screen.findByText("ADMIN")).toBeInTheDocument();
    expect(screen.getByText("USER")).toBeInTheDocument();
    expect(screen.getByTestId("role-toggle-10")).toHaveTextContent(
      /Desvincular/i,
    );
    expect(screen.getByTestId("role-toggle-20")).toHaveTextContent(
      /Vincular/i,
    );

    // bind USER
    await userEvent.click(screen.getByTestId("role-toggle-20"));
    await waitFor(() =>
      expect(
        findFetchCall(spy, "/sso-admin/write/1/role/20"),
      ).toBeDefined(),
    );
    expect(
      (findFetchCall(spy, "/sso-admin/write/1/role/20")![1] as RequestInit)
        .method,
    ).toBe("POST");

    // unbind ADMIN
    await userEvent.click(screen.getByTestId("role-toggle-10"));
    await waitFor(() =>
      expect(
        findFetchCall(spy, "/sso-admin/write/1/role/10"),
      ).toBeDefined(),
    );
    expect(
      (findFetchCall(spy, "/sso-admin/write/1/role/10")![1] as RequestInit)
        .method,
    ).toBe("DELETE");
  });

  it("deleting opens the confirm modal and on confirm fires DELETE /write/{id}", async () => {
    const w1 = mkWrite({ id: 33, uuid: "doomed-write" });
    const spy = buildFetchSpy({ writes: [w1] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("delete-33"));

    const dialog = await screen.findByRole("dialog", { name: /Eliminar write/i });
    expect(dialog).toBeInTheDocument();

    await userEvent.click(
      within(dialog).getByTestId("write-confirm-delete"),
    );

    await waitFor(() =>
      expect(findFetchCall(spy, "/sso-admin/write/33")).toBeDefined(),
    );
    const call = findFetchCall(spy, "/sso-admin/write/33")!;
    expect((call[1] as RequestInit).method).toBe("DELETE");
  });

  it("shows the empty-state copy when there are no writes", async () => {
    const spy = buildFetchSpy({ writes: [] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    expect(
      await screen.findByText("Aún no hay writes."),
    ).toBeInTheDocument();
  });

  /* ====================== microservice picker ====================== */

  it("Microservicio column resolves the FK id → instanceName + dialect from useMicroservices", async () => {
    const ms = mkMicroservice({
      id: 7,
      instanceName: "postgres",
      dialect: "postgres",
    });
    const w1 = mkWrite({ id: 1, microserviceId: 7 });
    const spy = buildFetchSpy({
      writes: [w1],
      microservices: [ms],
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    const cell = await screen.findByTestId("microservice-1");
    expect(cell).toHaveTextContent("#7");
    // instanceName + dialect both appear inline
    expect(cell).toHaveTextContent("postgres");
  });

  it("picking a QUERY microservice + a catalog table autofills tableName and the POST body carries microserviceId", async () => {
    const ms = mkMicroservice({
      id: 7,
      instanceName: "postgres",
      dialect: "postgres",
    });
    const tables: TableInfo[] = [
      { dialect: "postgres", schema: "public", name: "users", remarks: null },
      { dialect: "postgres", schema: "public", name: "orders", remarks: null },
    ];
    const spy = buildFetchSpy({
      writes: [],
      microservices: [ms],
      tablesByInstance: { "postgres::postgres": tables },
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("new-write"));

    // 1. Type UUID + default Tabla placeholder then we'll overwrite.
    await userEvent.type(screen.getByLabelText(/UUID/i), "smoke-write-mt");
    await userEvent.type(
      screen.getByTestId("write-columns-input"),
      "ID{Enter}",
    );

    // 2. Pick the QUERY microservice — this should enable the
    //    inline TablePicker panel.
    await userEvent.selectOptions(
      screen.getByTestId("write-microservice"),
      "7",
    );

    // 3. TablePicker select appears with the mock catalog rows.
    const pickerSelect = await screen.findByTestId("write-table-picker-select");
    await userEvent.selectOptions(pickerSelect, "public.users");

    // 4. Tabla input should now be "public.users".
    expect(screen.getByLabelText(/Tabla/i)).toHaveValue("public.users");

    // 5. Submit and assert POST carries both fields.
    await userEvent.click(screen.getByRole("button", { name: /^Crear$/i }));

    await waitFor(() =>
      expect(findFetchCall(spy, "/sso-admin/write/save")).toBeDefined(),
    );
    const call = findFetchCall(spy, "/sso-admin/write/save")!;
    const body = JSON.parse((call[1] as RequestInit).body as string);
    expect(body.uuid).toBe("smoke-write-mt");
    expect(body.tableName).toBe("public.users");
    expect(body.microserviceId).toBe(7);
  });

  it("without a microservice selected, the table picker panel does not render", async () => {
    const ms = mkMicroservice({ id: 7, instanceName: "postgres", dialect: "postgres" });
    const spy = buildFetchSpy({
      writes: [],
      microservices: [ms],
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("new-write"));

    // The <select> for the microservice exists and has only
    // the "Sin binding" option selected (default).
    expect(screen.getByTestId("write-microservice")).toBeInTheDocument();
    expect(screen.getByTestId("write-microservice")).toHaveValue("");

    // The TablePicker block is gated on selectedMs !== null.
    expect(
      screen.queryByTestId("write-table-picker"),
    ).not.toBeInTheDocument();
    // The /tables endpoint is never called — we have no fetch
    // for it in the spy, so a call would surface as
    // "Unexpected fetch" via the rejection path. Spy has not
    // been called for tables:
    const tablesCalls = spy.mock.calls.filter(([url]) => {
      const u = typeof url === "string" ? url : url.toString();
      return /\/query-service-[^/]+\/tables/.test(u);
    });
    expect(tablesCalls.length).toBe(0);
  });

  it("picking a table lights up the column picker, checkboxes drive the chips, and PKs auto-tick keyColumns", async () => {
    const ms = mkMicroservice({
      id: 7,
      instanceName: "postgres",
      dialect: "postgres",
    });
    const tables: TableInfo[] = [
      { dialect: "postgres", schema: "public", name: "users", remarks: null },
    ];
    const columns: ColumnInfo[] = [
      // PK — should auto-tick keyColumns on create.
      {
        dialect: "postgres",
        schema: "public",
        table: "users",
        name: "ID",
        dataType: "bigint",
        nullable: false,
        primaryKey: true,
      },
      {
        dialect: "postgres",
        schema: "public",
        table: "users",
        name: "NAME",
        dataType: "varchar",
        nullable: true,
        primaryKey: false,
      },
      {
        dialect: "postgres",
        schema: "public",
        table: "users",
        name: "EMAIL",
        dataType: "varchar",
        nullable: true,
        primaryKey: false,
      },
    ];
    const spy = buildFetchSpy({
      writes: [],
      microservices: [ms],
      tablesByInstance: { "postgres::postgres": tables },
      columnsByTable: { "postgres::public::users": columns },
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("new-write"));

    // Type UUID + seed a manual chip so we can confirm manual
    // input keeps working alongside the picker.
    await userEvent.type(screen.getByLabelText(/UUID/i), "smoke-cols");
    await userEvent.type(screen.getByTestId("write-columns-input"), "X{Enter}");

    // Without a microservice + a qualified `schema.table`, the
    // ColumnPicker is gated off (no fetch has happened).
    expect(screen.queryByTestId("write-columns-picker")).not.toBeInTheDocument();

    // Pick the microservice.
    await userEvent.selectOptions(
      screen.getByTestId("write-microservice"),
      "7",
    );

    // Pick a table — autofills `public.users`.
    const pickerSelect = await screen.findByTestId("write-table-picker-select");
    await userEvent.selectOptions(pickerSelect, "public.users");
    expect(screen.getByLabelText(/Tabla/i)).toHaveValue("public.users");

    // Now both ColumnPickers exist and the catalog has
    // arrived — assert the three columns show up with the
    // correct PK / nullable decoration.
    const colsPanel = await screen.findByTestId("write-columns-picker");
    expect(within(colsPanel).getByTestId("write-columns-picker-checkbox-ID")).toBeInTheDocument();
    expect(within(colsPanel).getByTestId("write-columns-picker-pk-ID")).toBeInTheDocument();
    expect(
      within(colsPanel).getByTestId("write-columns-picker-checkbox-EMAIL"),
    ).toBeInTheDocument();
    expect(
      within(colsPanel).queryByTestId("write-columns-picker-pk-EMAIL"),
    ).not.toBeInTheDocument();

    // The seeded manual chip "X" must still survive alongside
    // anything the picker is doing — manual overrides and
    // picker state share one underlying array.
    expect(screen.getByTestId("write-columns-chip-0")).toHaveTextContent("X");

    // Toggle the EMAIL checkbox on — chips array should gain it.
    await userEvent.click(
      within(colsPanel).getByTestId("write-columns-picker-checkbox-EMAIL"),
    );
    await waitFor(() =>
      expect(
        within(screen.getByTestId("write-columns")).getByText("EMAIL"),
      ).toBeInTheDocument(),
    );

    // The keyColumns picker auto-ticked the PK (ID) on mount
    // because the chip list was empty and the catalog had a
    // PK. Verify the chip array reflects that.
    const keyChips = screen.getByTestId("write-key-columns");
    expect(within(keyChips).getByText("ID")).toBeInTheDocument();
    expect(within(keyChips).queryByText("EMAIL")).not.toBeInTheDocument();

    // Submit and verify the picked columns land on the wire
    // as JSON-as-string in correct order, AND the keyColumns
    // PK auto-seed flows through too.
    await userEvent.click(screen.getByRole("button", { name: /^Crear$/i }));
    await waitFor(() =>
      expect(findFetchCall(spy, "/sso-admin/write/save")).toBeDefined(),
    );
    const body = JSON.parse(
      (findFetchCall(spy, "/sso-admin/write/save")![1] as RequestInit)
        .body as string,
    );
    // Chip order: ["X", "EMAIL"] (manually seeded X, picker toggled EMAIL).
    expect(body.columns).toBe('["X","EMAIL"]');
    // keyColumns = ["ID"] from the auto-PK seed.
    expect(body.keyColumns).toBe('["ID"]');
    expect(body.tableName).toBe("public.users");
    expect(body.microserviceId).toBe(7);
  });

  it("without a qualified `schema.table`, the column picker panels stay hidden even if a microservice is picked", async () => {
    const ms = mkMicroservice({
      id: 7,
      instanceName: "postgres",
      dialect: "postgres",
    });
    const spy = buildFetchSpy({
      writes: [],
      microservices: [ms],
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("new-write"));
    await userEvent.type(screen.getByLabelText(/UUID/i), "smoke-cols-none");

    // Pick microservice but leave Tabla blank — the picker
    // gates on a qualified `schema.table`.
    await userEvent.selectOptions(
      screen.getByTestId("write-microservice"),
      "7",
    );
    // Tabla input is empty — no qualified pair.
    expect(screen.getByLabelText(/Tabla/i)).toHaveValue("");
    expect(screen.queryByTestId("write-columns-picker")).not.toBeInTheDocument();
    expect(
      screen.queryByTestId("write-key-columns-picker"),
    ).not.toBeInTheDocument();

    // The /columns endpoint must not have been called.
    const colCalls = spy.mock.calls.filter(([url]) => {
      const u = typeof url === "string" ? url : url.toString();
      return /\/query-service-[^/]+\/columns/.test(u);
    });
    expect(colCalls.length).toBe(0);
  });

  /* ====================== column picker Tier 1 toolbar ====================== */

  it("ColumnPicker surfaces a search + bulk-action toolbar when the table has ≥5 columns", async () => {
    const ms = mkMicroservice({
      id: 7,
      instanceName: "postgres",
      dialect: "postgres",
    });
    const tables: TableInfo[] = [
      { dialect: "postgres", schema: "public", name: "orders", remarks: null },
    ];
    const columns: ColumnInfo[] = [
      "ID",
      "CUSTOMER_NAME",
      "EMAIL",
      "TOTAL",
      "STATUS",
      "CREATED_AT",
    ].map((name, i) => ({
      dialect: "postgres",
      schema: "public",
      table: "orders",
      name,
      dataType: i === 0 ? "bigint" : "varchar",
      nullable: name !== "ID",
      primaryKey: name === "ID",
    }));
    const spy = buildFetchSpy({
      writes: [],
      microservices: [ms],
      tablesByInstance: { "postgres::postgres": tables },
      columnsByTable: { "postgres::public::orders": columns },
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("new-write"));
    await userEvent.type(screen.getByLabelText(/UUID/i), "smoke-cols-search");

    await userEvent.selectOptions(screen.getByTestId("write-microservice"), "7");
    const pickerSelect = await screen.findByTestId("write-table-picker-select");
    await userEvent.selectOptions(pickerSelect, "public.orders");

    const panel = await screen.findByTestId("write-columns-picker");

    // 6 columns returned → search input shows (≥5 threshold).
    expect(within(panel).getByTestId("write-columns-picker-search")).toBeInTheDocument();
    expect(within(panel).getByTestId("write-columns-picker-select-all")).toBeInTheDocument();
    expect(within(panel).getByTestId("write-columns-picker-clear-visible")).toBeInTheDocument();

    // Counter reads "6 visibles · 0 seleccionadas" before any click.
    const counter = within(panel).getByTestId("write-columns-picker-visible-count");
    expect(counter).toHaveTextContent("6 visibles");
    expect(counter).toHaveTextContent("0 seleccionadas");

    // Type "E" — EMAIL, CUSTOMER_NAME, CREATED_AT all contain
    // an "e" (case-insensitive). ID, TOTAL, STATUS don't.
    await userEvent.type(
      within(panel).getByTestId("write-columns-picker-search"),
      "E",
    );
    expect(within(panel).queryByTestId("write-columns-picker-checkbox-ID")).not.toBeInTheDocument();
    expect(within(panel).getByTestId("write-columns-picker-checkbox-EMAIL")).toBeInTheDocument();
    expect(within(panel).getByTestId("write-columns-picker-checkbox-CUSTOMER_NAME")).toBeInTheDocument();
    expect(within(panel).getByTestId("write-columns-picker-checkbox-CREATED_AT")).toBeInTheDocument();
    expect(counter).toHaveTextContent("3 visibles");

    // "Seleccionar visibles" toggles everything currently visible
    // on; the chip list reflects the new selections.
    await userEvent.click(within(panel).getByTestId("write-columns-picker-select-all"));
    const cols = screen.getByTestId("write-columns");
    await waitFor(() => {
      expect(within(cols).getByText("EMAIL")).toBeInTheDocument();
      expect(within(cols).getByText("CUSTOMER_NAME")).toBeInTheDocument();
    });

    // Clear visible resets the chip list for the visible set.
    await userEvent.click(within(panel).getByTestId("write-columns-picker-clear-visible"));
    await waitFor(() => {
      expect(within(cols).queryByText("EMAIL")).not.toBeInTheDocument();
      expect(within(cols).queryByText("CUSTOMER_NAME")).not.toBeInTheDocument();
    });
  });

  it("ColumnPicker hides the search toolbar when the table has fewer than 5 columns", async () => {
    const ms = mkMicroservice({
      id: 7,
      instanceName: "postgres",
      dialect: "postgres",
    });
    const tables: TableInfo[] = [
      { dialect: "postgres", schema: "public", name: "small", remarks: null },
    ];
    // Only 3 columns — under the threshold.
    const columns: ColumnInfo[] = ["ID", "NAME", "STATUS"].map((name) => ({
      dialect: "postgres",
      schema: "public",
      table: "small",
      name,
      dataType: "varchar",
      nullable: name !== "ID",
      primaryKey: name === "ID",
    }));
    const spy = buildFetchSpy({
      writes: [],
      microservices: [ms],
      tablesByInstance: { "postgres::postgres": tables },
      columnsByTable: { "postgres::public::small": columns },
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("new-write"));
    await userEvent.selectOptions(screen.getByTestId("write-microservice"), "7");
    const pickerSelect = await screen.findByTestId("write-table-picker-select");
    await userEvent.selectOptions(pickerSelect, "public.small");

    const panel = await screen.findByTestId("write-columns-picker");
    // Search toolbar hidden — keeps the panel tidy for the
    // common 2-3 column case.
    expect(within(panel).queryByTestId("write-columns-picker-search")).not.toBeInTheDocument();
    // Checkboxes still work as before.
    expect(within(panel).getByTestId("write-columns-picker-checkbox-ID")).toBeInTheDocument();
  });
});
