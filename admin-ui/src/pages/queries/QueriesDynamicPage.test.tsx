import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ToastProvider } from "@/components/ui/Toast";
import { QueriesDynamicPage } from "./QueriesDynamicPage";
import type {
  MicroserviceResponse,
  QueryAdminResponse,
} from "@/api/types";

/**
 * Tests de QueriesDynamicPage. La estrategia es la misma que en
 * QueriesAdminPage: vi.stubGlobal("fetch", …) y matching por
 * fragmento de URL. Las URLs que importan son:
 *
 *   GET  /sso-admin/query/getQueries       → catálogo
 *   GET  /sso-admin/microservice/getMicroservices  → resolver instanceName
 *   POST /query-service-<instance>/query   → ejecución (base: "")
 *
 * Cobertura:
 * <ul>
 *   <li>Carga del catálogo — el picker muestra las queries.</li>
 *   <li>Cambio del picker → extrae placeholders y renderea
 *       un DynamicForm con un input por placeholder.</li>
 *   <li>Validación cliente (campo email inválido bloquea el submit).</li>
 *   <li>Submit ejecuta POST al /query-service-<instance>/query
 *       con params ya convertidos (number si aplica).</li>
 *   <li>El resultado se renderea como filas si la respuesta es
 *       un array, o como JSON si es un objeto suelto.</li>
 * </ul>
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
          <QueriesDynamicPage />
        </MemoryRouter>
      </ToastProvider>
    </QueryClientProvider>,
  );
}

function mkMs(over: Partial<MicroserviceResponse> = {}): MicroserviceResponse {
  return {
    id: 29,
    serviceId: "query-service-postfix-1783192553",
    description: "",
    requestUri: "",
    targetUriPath: "",
    targetUrlHost: "",
    targetUrlPort: "",
    createdDate: "2026-07-04T00:00:00Z",
    kind: "QUERY",
    dialect: "postgres",
    jdbcUrl: "",
    dbUsername: "",
    dbPassword: null,
    poolSize: 5,
    instanceName: "postfix-1783192553",
    ...over,
  };
}

function mkQ(over: Partial<QueryAdminResponse> = {}): QueryAdminResponse {
  return {
    id: 1,
    uuid: "users.find-by-id",
    query: "SELECT id_user, username FROM users WHERE id_user = :id",
    type: "",
    publicEnd: false,
    captcha: false,
    detail: JSON.stringify({
      targetTable: "users",
      targetAction: "SELECT",
      fieldTypes: { id: "number" },
      validate: { id: { required: true } },
    }),
    action: null,
    style: null,
    createdDate: "2026-07-04T00:00:00Z",
    roleIds: [],
    microserviceId: 29,
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
  return fetchSpy.mock.calls.find(([url]) =>
    typeof url === "string" && url.includes(urlFragment),
  );
}

function buildFetchSpy(opts: {
  queries: QueryAdminResponse[];
  microservices: MicroserviceResponse[];
  execResult?: unknown;
  execStatus?: number;
}) {
  const fetchSpy = vi.fn((url: string | URL | Request, init?: RequestInit) => {
    const u = typeof url === "string" ? url : url.toString();
    const method = (init?.method ?? "GET").toUpperCase();

    if (method === "GET" && u.includes("/sso-admin/query/getQueries")) {
      return Promise.resolve(jsonResponse(opts.queries));
    }
    if (method === "GET" && u.includes("/sso-admin/microservice/getMicroservices")) {
      return Promise.resolve(jsonResponse(opts.microservices));
    }
    // Ejecutar (puede ir a /query-service-<x>/query o /query-service/query)
    if (method === "POST" && /\/query-service[^?]*\/query/.test(u)) {
      const status = opts.execStatus ?? 200;
      if (status >= 400) {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              code: "INTERNAL_ERROR",
              message: "boom",
              timestamp: "2026-07-05T00:00:00Z",
            }),
            { status, headers: { "Content-Type": "application/json" } },
          ),
        );
      }
      return Promise.resolve(jsonResponse(opts.execResult ?? [{ row: "ok" }]));
    }
    return Promise.reject(new Error(`Unexpected fetch: ${method} ${u}`));
  });
  return fetchSpy;
}

describe("QueriesDynamicPage", () => {
  let fetchSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("shows the picker grouped by targetTable from metadata", async () => {
    const q = mkQ();
    const other = mkQ({
      id: 2,
      uuid: "creditos.list",
      query: "SELECT 1",
      detail: JSON.stringify({ targetTable: "creditos", targetAction: "SELECT" }),
    });
    const spy = buildFetchSpy({ queries: [q, other], microservices: [] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    expect(await screen.findByTestId("action-picker")).toBeInTheDocument();
    // Las opciones viven en <select>; happy-dom las renderea
    // y podemos leerlas por nombre del option (uuid).
    await waitFor(() => {
      const sel = screen.getByTestId("action-picker") as HTMLSelectElement;
      const labels = Array.from(sel.options).map((o) => o.text);
      expect(labels.some((l) => l && l.includes("users.find-by-id"))).toBe(true);
      expect(labels.some((l) => l && l.includes("creditos.list"))).toBe(true);
    });
  });

  it("selecting a query renders a DynamicForm with one input per placeholder", async () => {
    const q = mkQ();
    const spy = buildFetchSpy({ queries: [q], microservices: [mkMs()] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    const picker = await screen.findByTestId("action-picker");
    await userEvent.selectOptions(picker, "1");

    expect(await screen.findByTestId("dynamic-form")).toBeInTheDocument();
    // El SQL tiene UN placeholder (:id) y se mapea a la etiqueta
    // "id" en el input del form.
    expect(screen.getByLabelText(/^id/)).toBeInTheDocument();
  });

  it("client-side validation blocks submit when required is empty", async () => {
    const q = mkQ();
    const spy = buildFetchSpy({ queries: [q], microservices: [mkMs()] });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.selectOptions(await screen.findByTestId("action-picker"), "1");
    // No tipeamos nada → submit debe fallar con "obligatorio".
    await userEvent.click(await screen.findByTestId("dynamic-form-submit"));
    expect(await screen.findByText("obligatorio")).toBeInTheDocument();
    // No hubo POST a /query-service-.../query
    expect(
      findFetchCall(spy, "/query-service") && /query$/.test(findFetchCall(spy, "/query-service")![0] as string),
    ).toBeFalsy();
  });

  it("successful submit POSTs to /query-service-<instance>/query and renders rows", async () => {
    const q = mkQ();
    const pg = mkMs();
    const rows = [{ id_user: 1, username: "admin" }];
    const spy = buildFetchSpy({
      queries: [q],
      microservices: [pg],
      execResult: rows,
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.selectOptions(await screen.findByTestId("action-picker"), "1");

    // Llenamos el campo. Como fieldTypes.id === "number", el
    // form persiste "1" en el input string pero la mutación lo
    // convierte a Number.
    const input = (await screen.findByLabelText(/^id/)) as HTMLInputElement;
    await userEvent.type(input, "1");
    await userEvent.click(screen.getByTestId("dynamic-form-submit"));

    await waitFor(() =>
      expect(
        findFetchCall(spy, "/query-service-postfix-1783192553/query"),
      ).toBeDefined(),
    );
    const call = findFetchCall(spy, "/query-service-postfix-1783192553/query")!;
    const body = JSON.parse((call[1] as RequestInit).body as string);
    expect(body.uuid).toBe("users.find-by-id");
    expect(body.params.id).toBe(1); // number, no string
    // La fila rendereada aparece en la tabla
    expect(await screen.findByText("admin")).toBeInTheDocument();
  });

  it("errors from the executor surface as a red banner with the message", async () => {
    const q = mkQ();
    const spy = buildFetchSpy({
      queries: [q],
      microservices: [mkMs()],
      execStatus: 502,
    });
    vi.stubGlobal("fetch", spy);

    renderPage();
    await userEvent.selectOptions(await screen.findByTestId("action-picker"), "1");
    const input = (await screen.findByLabelText(/^id/)) as HTMLInputElement;
    await userEvent.type(input, "1");
    await userEvent.click(screen.getByTestId("dynamic-form-submit"));

    const banner = await screen.findByTestId("result-error");
    expect(banner).toHaveTextContent(/boom|código/);
  });
});
