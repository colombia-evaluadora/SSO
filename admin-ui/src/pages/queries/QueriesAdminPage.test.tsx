import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { render, screen, waitFor, within, fireEvent } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ToastProvider } from "@/components/ui/Toast";
import { QueriesAdminPage } from "./QueriesAdminPage";
import type {
  MicroserviceResponse,
  QueryAdminResponse,
  QueryRoleChecked,
} from "@/api/types";

/**
 * Tests for the admin CRUD page. Like the consumer-catalog
 * tests, fetch is stubbed via {@code vi.stubGlobal("fetch", …)}
 * and we dispatch by URL fragment so TanStack Query's
 * non-deterministic parallel fetch order doesn't matter.
 *
 * Coverage scope:
 * <ul>
 *   <li>The page renders the rows from {@code GET /query/getQueries}.</li>
 *   <li>"+ Nuevo query" opens the drawer; submitting it posts
 *       to {@code POST /query/save} with {@code microserviceId}
 *       if one was picked.</li>
 *   <li>The Microservicio dropdown in the drawer is filtered
 *       to {@code kind=QUERY} only — REST rows must NOT
 *       appear.</li>
 *   <li>"Roles" opens a modal that lists the role bindings and
 *       lets the user toggle each one (POST or DELETE
 *       {@code /query/{id}/role/{roleId}}).</li>
 *   <li>Delete opens a confirm modal; on confirm,
 *       {@code DELETE /query/{id}} fires.</li>
 * </ul>
 *
 * Validation, error envelope, etc. are exercised end-to-end in
 * the smoke scripts; we don't try to cover Bean Validation
 * surface area twice.
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
          <QueriesAdminPage />
        </MemoryRouter>
      </ToastProvider>
    </QueryClientProvider>,
  );
}

function mkMs(over: Partial<MicroserviceResponse> = {}): MicroserviceResponse {
  return {
    id: 1,
    serviceId: "query-pg",
    description: "pg dev",
    requestUri: "/api/queries/**",
    targetUriPath: "",
    targetUrlHost: "",
    targetUrlPort: "",
    createdDate: "2026-06-01T00:00:00Z",
    kind: "QUERY",
    dialect: "postgres",
    jdbcUrl: "jdbc:postgresql://db:5432/sso",
    dbUsername: "sso",
    dbPassword: null,
    poolSize: 10,
    instanceName: "pg",
    fileStorageSchema: null,
    fileStorageTable: null,
    ...over,
  };
}

function mkQuery(over: Partial<QueryAdminResponse> = {}): QueryAdminResponse {
  return {
    id: 1,
    uuid: "q-1",
    query: "SELECT * FROM t WHERE id = :id",
    type: "select",
    publicEnd: true,
    captcha: false,
    detail: null,
    action: null,
    style: null,
    createdDate: "2026-06-01T00:00:00Z",
    roleIds: [],
    microserviceId: null,
    ...over,
  };
}

function mkRole(r: Partial<QueryRoleChecked>): QueryRoleChecked {
  return { roleId: 1, name: "ADMIN", checked: false, ...r };
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function findFetchCall(fetchSpy: ReturnType<typeof vi.fn>, urlFragment: string) {
  return fetchSpy.mock.calls.find(([url]) =>
    typeof url === "string" && url.includes(urlFragment),
  );
}

/**
 * Build a fetch spy keyed off the URL fragment so the
 * parallel-mount fetches don't fight over a queue. Unknown
 * URLs reject so a regression in the wiring shows up loud.
 */
function buildFetchSpy(opts: {
  queries: QueryAdminResponse[];
  microservices: MicroserviceResponse[];
  rolesForId?: Record<number, QueryRoleChecked[]>;
  executeResult?: { status: number; body: unknown; isError?: boolean };
}) {
  const fetchSpy = vi.fn((url: string | URL | Request, init?: RequestInit) => {
    const u = typeof url === "string" ? url : url.toString();
    const method = (init?.method ?? "GET").toUpperCase();
    if (method === "GET" && u.includes("/sso-admin/microservice/getMicroservices")) {
      return Promise.resolve(jsonResponse(opts.microservices));
    }
    if (method === "GET" && u.includes("/sso-admin/query/getQueries")) {
      return Promise.resolve(jsonResponse(opts.queries));
    }
    // Query execution — POST /query-service[-<instance>]/query
    // (no /sso-admin prefix; the apiClient `base: ""` override).
    if (method === "POST" && u.includes("/query-service") && u.endsWith("/query")) {
      if (opts.executeResult?.isError) {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              code: "BAD",
              message: opts.executeResult.body as string,
              timestamp: "",
            }),
            { status: opts.executeResult.status, headers: { "Content-Type": "application/json" } },
          ),
        );
      }
      return Promise.resolve(jsonResponse(opts.executeResult?.body ?? []));
    }
    // Role toggles (POST or DELETE) and the role-checked fetch
    const roleToggleMatch = u.match(/\/sso-admin\/query\/(\d+)\/role\/(\d+)$/);
    if (roleToggleMatch) {
      // 204 No Content — Jackson won't get a chance to parse
      // an empty body either way.
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    const roleCheckedMatch = u.match(/\/sso-admin\/query\/(\d+)\/roles\/checked$/);
    if (method === "GET" && roleCheckedMatch) {
      const id = Number(roleCheckedMatch[1]);
      return Promise.resolve(jsonResponse(opts.rolesForId?.[id] ?? []));
    }
    // POST save, PUT update, DELETE id — all return the row
    // or a No-Content (we just want the call URL recorded).
    if (
      (method === "POST" && u.includes("/sso-admin/query/save")) ||
      (method === "PUT" && u.includes("/sso-admin/query/update"))
    ) {
      // Echo the body back as the saved row.
      const body = JSON.parse((init?.body as string) ?? "{}");
      return Promise.resolve(jsonResponse({ id: 999, roleIds: [], createdDate: null, ...body }));
    }
    if (method === "DELETE" && /\/sso-admin\/query\/\d+$/.test(u)) {
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    return Promise.reject(new Error(`Unexpected fetch: ${method} ${u}`));
  });
  return fetchSpy;
}

describe("QueriesAdminPage", () => {
  let fetchSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("renders rows from /getQueries", async () => {
    const q1 = mkQuery({ id: 1, uuid: "alpha" });
    const q2 = mkQuery({ id: 2, uuid: "beta", type: "report" });
    const spy = buildFetchSpy({ queries: [q1, q2], microservices: [] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    expect(await screen.findByText("alpha")).toBeInTheDocument();
    expect(screen.getByText("beta")).toBeInTheDocument();
    expect(screen.getByText("select")).toBeInTheDocument();
    expect(screen.getByText("report")).toBeInTheDocument();
    expect(screen.getByTestId("edit-1")).toBeInTheDocument();
    expect(screen.getByTestId("delete-1")).toBeInTheDocument();
    expect(screen.getByTestId("bind-roles-1")).toBeInTheDocument();
  });

  it("renders path-template next to uuid when the query has one", async () => {
    // Filas con path-template exponen la URL completa del query-service
    // debajo del uuid. Sin path-template (legacy uuid-in-body) la
    // línea secundaria se omite para no sugerir un endpoint que no
    // existe.
    const exposed = mkQuery({
      id: 1,
      uuid: "reporte-ventas",
      pathTemplate: "/reporte/ventas",
      httpMethod: "GET",
    });
    const legacy = mkQuery({ id: 2, uuid: "legacy-uuid-only" });
    const spy = buildFetchSpy({
      queries: [exposed, legacy],
      microservices: [],
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    expect(await screen.findByTestId("query-uuid-1")).toHaveTextContent(
      "reporte-ventas",
    );
    const pathEl = await screen.findByTestId("query-path-template-1");
    expect(pathEl).toHaveTextContent("GET");
    expect(pathEl).toHaveTextContent("/reporte/ventas");

    // Legacy row: no path-template child. The testid is absent.
    expect(
      screen.queryByTestId("query-path-template-2"),
    ).not.toBeInTheDocument();
  });

  it("search box also matches the path template, not just uuid/type", async () => {
    const byPath = mkQuery({
      id: 1,
      uuid: "alpha",
      type: "select",
      pathTemplate: "/establecimientos/sedes/query",
      httpMethod: "POST",
    });
    const other = mkQuery({ id: 2, uuid: "beta", type: "report" });
    const spy = buildFetchSpy({ queries: [byPath, other], microservices: [] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await screen.findByText("alpha");
    expect(screen.getByText("beta")).toBeInTheDocument();

    const search = screen.getByPlaceholderText(/Buscar por UUID, tipo o path/i);
    await userEvent.type(search, "sedes/query");

    expect(screen.getByText("alpha")).toBeInTheDocument();
    expect(screen.queryByText("beta")).not.toBeInTheDocument();
  });

  it("the method select filters rows by httpMethod (default POST when null)", async () => {
    const getRow = mkQuery({ id: 1, uuid: "get-row", httpMethod: "GET" });
    const postRow = mkQuery({ id: 2, uuid: "post-row", httpMethod: null });
    const putRow = mkQuery({ id: 3, uuid: "put-row", httpMethod: "PUT" });
    const spy = buildFetchSpy({
      queries: [getRow, postRow, putRow],
      microservices: [],
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await screen.findByText("get-row");
    expect(screen.getByText("post-row")).toBeInTheDocument();
    expect(screen.getByText("put-row")).toBeInTheDocument();

    const select = screen.getByTestId("method-filter");
    await userEvent.selectOptions(select, "GET");
    expect(screen.getByText("get-row")).toBeInTheDocument();
    expect(screen.queryByText("post-row")).not.toBeInTheDocument();
    expect(screen.queryByText("put-row")).not.toBeInTheDocument();

    // Null httpMethod counts as POST — the default the backend applies.
    await userEvent.selectOptions(select, "POST");
    expect(screen.getByText("post-row")).toBeInTheDocument();
    expect(screen.queryByText("get-row")).not.toBeInTheDocument();

    await userEvent.selectOptions(select, "");
    expect(screen.getByText("get-row")).toBeInTheDocument();
    expect(screen.getByText("post-row")).toBeInTheDocument();
    expect(screen.getByText("put-row")).toBeInTheDocument();
  });

  it("defaults the httpMethod to POST when it is null in the response", async () => {
    // null httpMethod is the legacy wire shape (pre-V33). The cell
    // must still render — POST is the historical default — so the
    // URL the admin sees matches what the dispatcher actually does.
    const q = mkQuery({
      id: 1,
      uuid: "by-uuid-legacy",
      pathTemplate: "/legacy/path",
      httpMethod: null,
    });
    const spy = buildFetchSpy({ queries: [q], microservices: [] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    const pathEl = await screen.findByTestId("query-path-template-1");
    expect(pathEl).toHaveTextContent("POST");
    expect(pathEl).toHaveTextContent("/legacy/path");
  });

  it("resolves the microservice column via /getMicroservices and falls back to #<id>", async () => {
    const pg = mkMs({ id: 7, instanceName: "pg-prod", dialect: "postgres" });
    const q = mkQuery({ id: 1, uuid: "q-bound", microserviceId: 7 });
    const qOrphan = mkQuery({ id: 2, uuid: "q-orphan", microserviceId: 999 });
    const spy = buildFetchSpy({ queries: [q, qOrphan], microservices: [pg] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    expect(await screen.findByText("pg-prod")).toBeInTheDocument();
    // Orphan resolves to "#999"
    expect(screen.getByText("#999")).toBeInTheDocument();
  });

  it("only allows QUERY-kind microservices in the new-query drawer", async () => {
    const restRow = mkMs({
      id: 10,
      kind: "REST",
      instanceName: null,
      requestUri: "/api/orders/**",
      targetUriPath: "/v1",
      targetUrlHost: "orders.internal",
      targetUrlPort: "8080",
    });
    const queryRow = mkMs({ id: 11, instanceName: "pg" });
    const spy = buildFetchSpy({ queries: [], microservices: [restRow, queryRow] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(screen.getByTestId("new-query"));
    // The drawer exposes a <select>; wait for microservice data
    // to land before reading the options.
    await screen.findByRole("option", { name: /pg/i });
    const select = screen.getByLabelText(/Microservicio/i) as HTMLSelectElement;
    const labels = Array.from(select.options).map((o) => o.text);
    expect(labels.some((l) => l && l.includes("orders"))).toBe(false);
    expect(labels.some((l) => l && l.includes("pg"))).toBe(true);
    // "Sin binding (global)" must always be present
    expect(labels.some((l) => l && /Sin binding/.test(l))).toBe(true);
  });

  it("submitting the new-query drawer POSTs to /query/save with the microservice binding", async () => {
    const pg = mkMs({ id: 7, instanceName: "pg-prod" });
    const spy = buildFetchSpy({ queries: [], microservices: [pg] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(screen.getByTestId("new-query"));

    // El UUID ya viene puesto: es automático y read-only en el
    // modo "nuevo". Solo se captura para afirmarlo en el body.
    const uuidInput = screen.getByLabelText(/UUID/i) as HTMLInputElement;
    expect(uuidInput).toHaveAttribute("readonly");
    const autoUid = uuidInput.value;
    expect(autoUid).toMatch(/^[a-zA-Z0-9_-]{2,64}$/);

    const sqlArea = screen.getByLabelText(/SQL/i);
    await userEvent.type(sqlArea, "SELECT 1");

    // Wait for the microservice dropdown to populate.
    await screen.findByRole("option", { name: /pg-prod/i });
    await userEvent.selectOptions(screen.getByLabelText(/Microservicio/i), "7");

    // Submit
    await userEvent.click(screen.getByRole("button", { name: /Crear/i }));

    await waitFor(() =>
      expect(
        findFetchCall(spy, "/sso-admin/query/save"),
      ).toBeDefined(),
    );
    const call = findFetchCall(spy, "/sso-admin/query/save");
    expect(call).toBeDefined();
    const body = JSON.parse((call![1] as RequestInit).body as string);
    expect(body.uuid).toBe(autoUid);
    expect(body.query).toBe("SELECT 1");
    expect(body.microserviceId).toBe(7);
  });

  /**
   * Regression: the drawer's V27/V28/V31 fields (executionMode,
   * pathTemplate, outParamNames) MUST end up on the wire. The
   * form, schema, types, and backend service all carry them —
   * but the parent page's handleSubmit was building the body
   * field-by-field and quietly dropping these three. Result:
   * the user filled them in, hit save, the toast said success,
   * and on reload the fields were empty again. This test pins
   * the wire shape so a future refactor can't reintroduce the
   * silence.
   */
  it("submitting the new-query drawer forwards pathTemplate and outParamNames, and no longer sends the derived fields", async () => {
    const pg = mkMs({ id: 7, instanceName: "pg-prod" });
    const spy = buildFetchSpy({ queries: [], microservices: [pg] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(screen.getByTestId("new-query"));

    // Un CALL, que es lo que hace que el backend derive
    // PROCEDURE y que el campo de OUT params aparezca.
    const sqlArea = screen.getByLabelText(/SQL/i);
    await userEvent.type(
      sqlArea,
      "CALL get_establecimiento(:PARAM.ID, :out_status, :out_message)",
    );

    await screen.findByRole("option", { name: /pg-prod/i });
    await userEvent.selectOptions(screen.getByLabelText(/Microservicio/i), "7");

    // La plantilla se fija con fireEvent.change y no con
    // userEvent.type porque éste interpreta las llaves como
    // atajos de teclado ({enter}, {tab}…). La sintaxis nueva no
    // lleva llaves, pero seguimos usando change: la intención es
    // "pon este valor", no "simula tecleo".
    const pathInput = screen.getByLabelText(/Path template/i) as HTMLInputElement;
    fireEvent.change(pathInput, { target: { value: "/establecimiento/:ID" } });

    const outInput = await screen.findByLabelText(/OUT params/i);
    await userEvent.type(outInput, ":out_status,:out_message");

    await userEvent.click(screen.getByRole("button", { name: /Crear/i }));

    await waitFor(() =>
      expect(findFetchCall(spy, "/sso-admin/query/save")).toBeDefined(),
    );
    const body = JSON.parse(
      (findFetchCall(spy, "/sso-admin/query/save")![1] as RequestInit).body as string,
    );

    expect(body.pathTemplate).toBe("/establecimiento/:ID");
    expect(body.outParamNames).toBe(":out_status,:out_message");
    // Derivados en el backend: mandarlos desde el formulario sólo
    // permitiría que contradijeran al SQL.
    expect(body).not.toHaveProperty("executionMode");
    expect(body).not.toHaveProperty("type");
  });

  /**
   * Companion regression: editing an existing row preserves
   * the wire shape. The bug was symmetric on update — the
   * same handleSubmit is used for both create and update, so
   * the existing test ("submitting the new-query drawer …")
   * arguably covers both. But pinning the update path
   * separately catches the case where someone refactors the
   * branches apart and only fixes one.
   */
  it("editing an existing query forwards pathTemplate and outParamNames on PUT", async () => {
    const pg = mkMs({ id: 7, instanceName: "pg-prod" });
    const q = mkQuery({
      id: 42,
      uuid: "q-exec",
      query: "CALL get_establecimiento(:PARAM.ID, :out_status, :out_message)",
      microserviceId: 7,
      executionMode: "PROCEDURE",
      pathTemplate: "/establecimiento/:ID",
      outParamNames: ":out_status,:out_message",
    });
    const spy = buildFetchSpy({ queries: [q], microservices: [pg] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("edit-42"));

    // The drawer pre-fills the existing values; change the path
    // template to make sure the new value is what lands on the
    // wire (not a stale initial). fireEvent.change avoids the
    // {placeholder} shortcut that user-event.type consumes.
    const pathInput = screen.getByLabelText(/Path template/i) as HTMLInputElement;
    fireEvent.change(pathInput, {
      target: { value: "/establecimiento/:ID/detalle" },
    });

    await userEvent.click(screen.getByRole("button", { name: /Guardar cambios/i }));

    await waitFor(() =>
      expect(findFetchCall(spy, "/sso-admin/query/update")).toBeDefined(),
    );
    const body = JSON.parse(
      (findFetchCall(spy, "/sso-admin/query/update")![1] as RequestInit).body as string,
    );
    expect(body.pathTemplate).toBe("/establecimiento/:ID/detalle");
    expect(body.outParamNames).toBe(":out_status,:out_message");
    expect(body).not.toHaveProperty("executionMode");
    expect(body).not.toHaveProperty("type");
  });

  it("mints a fresh auto-UID each time the new-query drawer opens", async () => {
    const spy = buildFetchSpy({ queries: [], microservices: [] });
    vi.stubGlobal("fetch", spy);

    renderPage();

    await userEvent.click(screen.getByTestId("new-query"));
    const first = (screen.getByLabelText(/UUID/i) as HTMLInputElement).value;
    await userEvent.click(screen.getByRole("button", { name: /Cancelar/i }));

    await userEvent.click(screen.getByTestId("new-query"));
    const second = (screen.getByLabelText(/UUID/i) as HTMLInputElement).value;

    // Reusar el UID chocaría contra el unique de la columna UUID
    // en el segundo create.
    expect(second).not.toBe(first);
  });

  it("Regenerar swaps the auto-UID for a new one", async () => {
    const spy = buildFetchSpy({ queries: [], microservices: [] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(screen.getByTestId("new-query"));

    const input = screen.getByLabelText(/UUID/i) as HTMLInputElement;
    const before = input.value;
    await userEvent.click(screen.getByRole("button", { name: /Regenerar/i }));

    expect(input.value).not.toBe(before);
    expect(input.value).toMatch(/^[a-zA-Z0-9_-]{2,64}$/);
  });

  it("opening the Roles modal lists the role-binding checkboxes from /roles/checked", async () => {
    const roles: QueryRoleChecked[] = [
      mkRole({ roleId: 10, name: "ADMIN", checked: true }),
      mkRole({ roleId: 20, name: "USER", checked: false }),
    ];
    const q = mkQuery({ id: 5, uuid: "q-roles" });
    const spy = buildFetchSpy({
      queries: [q],
      microservices: [],
      rolesForId: { 5: roles },
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("bind-roles-5"));

    // Modal lists role names
    expect(await screen.findByText("ADMIN")).toBeInTheDocument();
    expect(screen.getByText("USER")).toBeInTheDocument();
    // Toggle buttons labelled per-state
    expect(screen.getByTestId("role-toggle-10")).toHaveTextContent(/Desvincular/i);
    expect(screen.getByTestId("role-toggle-20")).toHaveTextContent(/Vincular/i);
  });

  it("clicking Vincular fires POST /query/{id}/role/{roleId}", async () => {
    const roles: QueryRoleChecked[] = [
      mkRole({ roleId: 20, name: "USER", checked: false }),
    ];
    const q = mkQuery({ id: 5, uuid: "q-roles" });
    const spy = buildFetchSpy({
      queries: [q],
      microservices: [],
      rolesForId: { 5: roles },
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("bind-roles-5"));
    await userEvent.click(await screen.findByTestId("role-toggle-20"));

    await waitFor(() =>
      expect(
        findFetchCall(spy, "/sso-admin/query/5/role/20"),
      ).toBeDefined(),
    );
    // It must be a POST (the bind half)
    const call = findFetchCall(spy, "/sso-admin/query/5/role/20")!;
    expect((call[1] as RequestInit).method).toBe("POST");
  });

  it("clicking Desvincular fires DELETE /query/{id}/role/{roleId}", async () => {
    const roles: QueryRoleChecked[] = [
      mkRole({ roleId: 11, name: "ADMIN", checked: true }),
    ];
    const q = mkQuery({ id: 8, uuid: "q-roles-2" });
    const spy = buildFetchSpy({
      queries: [q],
      microservices: [],
      rolesForId: { 8: roles },
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("bind-roles-8"));
    await userEvent.click(await screen.findByTestId("role-toggle-11"));

    await waitFor(() =>
      expect(
        findFetchCall(spy, "/sso-admin/query/8/role/11"),
      ).toBeDefined(),
    );
    const call = findFetchCall(spy, "/sso-admin/query/8/role/11")!;
    expect((call[1] as RequestInit).method).toBe("DELETE");
  });

  it("deleting a row opens the confirm modal and on confirm fires DELETE /query/{id}", async () => {
    const q = mkQuery({ id: 33, uuid: "doomed" });
    const spy = buildFetchSpy({ queries: [q], microservices: [] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("delete-33"));

    // Confirm modal
    const dialog = await screen.findByRole("dialog", { name: /Eliminar query/i });
    expect(dialog).toBeInTheDocument();
    // The "Eliminar" button inside the modal footer is the only
    // one bound to the danger-confirm handler — the row's
    // button just opens this dialog. Use the scoped query to
    // disambiguate.
    await userEvent.click(
      within(dialog).getByRole("button", { name: /^Eliminar$/i }),
    );

    await waitFor(() =>
      expect(findFetchCall(spy, "/sso-admin/query/33")).toBeDefined(),
    );
    const call = findFetchCall(spy, "/sso-admin/query/33")!;
    expect((call[1] as RequestInit).method).toBe("DELETE");
  });

  it("clicking 'Ejecutar' opens the drawer with the SQL and a param input", async () => {
    const pg = mkMs({ id: 1, instanceName: "pg" });
    const q = mkQuery({
      id: 7,
      uuid: "q-param",
      query: "SELECT * FROM t WHERE id = :id AND name = :name",
      microserviceId: 1,
    });
    const spy = buildFetchSpy({ queries: [q], microservices: [pg] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("execute-7"));

    expect(
      await screen.findByRole("dialog", { name: /Ejecutar consulta q-param/i }),
    ).toBeInTheDocument();
    expect(screen.getByTestId("param-id")).toBeInTheDocument();
    expect(screen.getByTestId("param-name")).toBeInTheDocument();
    expect(screen.getByTestId("run-execute")).toBeInTheDocument();
  });

  it("submitting Execute POSTs to /query-service-<instance>/query and renders the result", async () => {
    const pg = mkMs({ id: 1, instanceName: "pg-prod" });
    const q = mkQuery({
      id: 7,
      uuid: "q-param",
      query: "SELECT id, name FROM t WHERE id = :id",
      microserviceId: 1,
    });
    const execResult = [{ id: 1, name: "alice" }, { id: 2, name: "bob" }];
    const spy = buildFetchSpy({
      queries: [q],
      microservices: [pg],
      executeResult: { status: 200, body: execResult },
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("execute-7"));
    await userEvent.type(screen.getByTestId("param-id"), "1");
    await userEvent.click(screen.getByTestId("run-execute"));

    await waitFor(() =>
      expect(findFetchCall(spy, "/query-service-pg-prod/query")).toBeDefined(),
    );
    const execCall = findFetchCall(spy, "/query-service-pg-prod/query")!;
    const bodyArg = JSON.parse((execCall[1] as RequestInit).body as string);
    expect(bodyArg).toEqual({ uuid: "q-param", params: { id: "1" } });

    expect(await screen.findByText("2 fila(s) devueltas")).toBeInTheDocument();
    expect(screen.getByText("alice")).toBeInTheDocument();
    expect(screen.getByText("bob")).toBeInTheDocument();
  });

  it("uses the canonical /query-service/query path for a global query (no microserviceId)", async () => {
    const globalQ = mkQuery({
      id: 42,
      uuid: "q-global",
      query: "SELECT 1",
      microserviceId: null,
    });
    const spy = buildFetchSpy({
      queries: [globalQ],
      microservices: [],
      executeResult: { status: 200, body: [{ "?column?": 1 }] },
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.click(await screen.findByTestId("execute-42"));
    await userEvent.click(screen.getByTestId("run-execute"));

    await waitFor(() =>
      expect(findFetchCall(spy, "/query-service/query")).toBeDefined(),
    );
    expect(
      screen.getByText(/Instancia: query-service \(canónica\)/i),
    ).toBeInTheDocument();
  });
});
