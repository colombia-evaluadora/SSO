import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ToastProvider } from "@/components/ui/Toast";
import { QueryServicesSection } from "./QueryServicesSection";
import type { ContainerStatusResponse, MicroserviceResponse } from "@/api/types";

/**
 * Renders the page with a fresh QueryClient (staleTime 0, retry
 * off, no refetch-on-focus) and a MemoryRouter so the
 * `<Link>` in the empty/error states would resolve if it ever
 * fires. We stub `fetch` because the hooks call
 * /sso-admin/microservice/getMicroservices and the per-row
 * /container/status endpoint.
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
          <QueryServicesSection />
        </MemoryRouter>
      </ToastProvider>
    </QueryClientProvider>,
  );
}

function mkMs(over: Partial<MicroserviceResponse> = {}): MicroserviceResponse {
  return {
    id: 1,
    serviceId: "query-oracle-dev",
    description: "dev oracle",
    requestUri: "/api/queries/**",
    targetUriPath: "",
    targetUrlHost: "",
    targetUrlPort: "",
    createdDate: "2026-06-01T00:00:00Z",
    kind: "QUERY",
    dialect: "oracle",
    jdbcUrl: "jdbc:oracle:thin:@db:1521/ORCLPDB1",
    dbUsername: "query",
    dbPassword: null,
    poolSize: 10,
    instanceName: "oracle-dev",
    ...over,
  };
}

function mkStatus(over: Partial<ContainerStatusResponse> = {}): ContainerStatusResponse {
  return {
    state: "running",
    rawState: "running",
    containerId: "abc123",
    startedAt: "2026-06-24T10:00:00.000Z",
    fullName: "query-service-oracle-dev",
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
  return fetchSpy.mock.calls.find(([url]) => typeof url === "string" && url.includes(urlFragment));
}

describe("QueryServicesSection", () => {
  let fetchSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("renders an empty state when there are no QUERY rows", async () => {
    fetchSpy.mockResolvedValueOnce(jsonResponse([])); // getMicroservices
    renderPage();
    expect(await screen.findByText(/Aún no hay query services/i)).toBeInTheDocument();
    // The page must NOT call /container/status when the list is empty
    // (each row's hook is `enabled: id != null`, and id is null until
    // a row exists). Empty list → zero status calls.
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(1));
  });

  it("renders one row per QUERY microservice with status badge and jdbc url", async () => {
    const row1 = mkMs({ id: 1, serviceId: "q-oracle", instanceName: "oracle-dev" });
    const row2 = mkMs({
      id: 2,
      serviceId: "q-pg",
      dialect: "postgres",
      jdbcUrl: "jdbc:postgresql://db/pg",
      instanceName: "pg",
    });
    fetchSpy.mockResolvedValueOnce(jsonResponse([row1, row2])); // list
    fetchSpy.mockResolvedValueOnce(
      jsonResponse(mkStatus({ state: "running", rawState: "running" })),
    ); // status row1
    fetchSpy.mockResolvedValueOnce(
      jsonResponse(mkStatus({ state: "running", rawState: "running" })),
    ); // status row2

    renderPage();
    expect(await screen.findByText("q-oracle")).toBeInTheDocument();
    expect(screen.getByText("q-pg")).toBeInTheDocument();

    // Each row has a StatusBadge (data-state=running) and a
    // "Ver logs" + "Reiniciar" button.
    expect(screen.getAllByTestId("status-cell-1")[0]).toHaveTextContent(/UP/);
    expect(screen.getAllByTestId("status-cell-2")[0]).toHaveTextContent(/UP/);
    expect(screen.getByTestId("view-logs-1")).toBeInTheDocument();
    expect(screen.getByTestId("view-logs-2")).toBeInTheDocument();
  });

  it("filters out REST rows from the list", async () => {
    const restRow = mkMs({
      id: 99,
      serviceId: "orders",
      kind: "REST",
      requestUri: "/api/orders/**",
      targetUriPath: "/v1",
      targetUrlHost: "orders.internal",
      targetUrlPort: "8080",
    });
    const queryRow = mkMs({ id: 1, serviceId: "q-oracle" });
    fetchSpy.mockResolvedValueOnce(jsonResponse([restRow, queryRow]));
    fetchSpy.mockResolvedValueOnce(jsonResponse(mkStatus()));

    renderPage();
    expect(await screen.findByText("q-oracle")).toBeInTheDocument();
    expect(screen.queryByText("orders")).not.toBeInTheDocument();
    // Exactly one status call (only the QUERY row, not the REST one)
    await waitFor(() =>
      expect(
        fetchSpy.mock.calls.filter(
          ([u]) => typeof u === "string" && u.includes("/container/status"),
        ),
      ).toHaveLength(1),
    );
  });

  it("opens the Logs modal with logs body when 'Ver logs' is clicked", async () => {
    const row = mkMs({ id: 7, instanceName: "oracle-dev" });
    fetchSpy.mockResolvedValueOnce(jsonResponse([row]));
    fetchSpy.mockResolvedValueOnce(jsonResponse(mkStatus()));
    // The apiClient decodes the body via resp.json() — a JSON-encoded
    // string is what the production logs endpoint returns.
    fetchSpy.mockResolvedValueOnce(jsonResponse("Hello\nworld\n"));

    renderPage();
    await userEvent.click(await screen.findByTestId("view-logs-7"));

    const body = await screen.findByTestId("logs-body");
    expect(body).toHaveTextContent(/Hello/);
    expect(body).toHaveTextContent(/world/);
    // Logs request should hit /container/logs?tail=200
    expect(findFetchCall(fetchSpy, "/container/logs?tail=200")).toBeDefined();
  });

  it("fires a restart POST and toasts on success", async () => {
    const row = mkMs({ id: 4, instanceName: "oracle-dev" });
    fetchSpy.mockResolvedValueOnce(jsonResponse([row]));
    fetchSpy.mockResolvedValueOnce(jsonResponse(mkStatus()));
    // restart returns 204 No Content
    fetchSpy.mockResolvedValueOnce(new Response(null, { status: 204 }));

    renderPage();
    const restartBtn = await screen.findByRole("button", { name: /Reiniciar/i });
    await userEvent.click(restartBtn);

    expect(findFetchCall(fetchSpy, "/microservice/4/container/restart")).toBeDefined();
    expect(await screen.findByText(/Reinicio solicitado — oracle-dev/i)).toBeInTheDocument();
  });

  it("renders an error state when the list endpoint fails", async () => {
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify({ code: "DOWN", message: "sso-admin down", timestamp: "" }), {
        status: 503,
        headers: { "Content-Type": "application/json" },
      }),
    );
    renderPage();
    expect(await screen.findByText(/sso-admin está UP/i)).toBeInTheDocument();
  });

  it("renders PROVISIONING badge while the container is starting", async () => {
    const row = mkMs({ id: 5 });
    fetchSpy.mockResolvedValueOnce(jsonResponse([row]));
    fetchSpy.mockResolvedValueOnce(
      jsonResponse(mkStatus({ state: "provisioning", rawState: "provisioning" })),
    );
    renderPage();
    const cell = await screen.findByTestId("status-cell-5");
    expect(cell).toHaveTextContent(/PROVISIONING/);
    expect(cell.querySelector("[data-state='provisioning']")).toBeInTheDocument();
  });

  it("creates a QUERY service via the drawer, POSTing kind=QUERY to /microservice/save", async () => {
    fetchSpy.mockResolvedValueOnce(jsonResponse([])); // empty list
    const createdRow = mkMs({ id: 1, serviceId: "diag-svc", instanceName: "diag" });
    fetchSpy.mockResolvedValue(jsonResponse(createdRow)); // save + any refetch

    const user = userEvent.setup();
    renderPage();

    await user.click(await screen.findByTestId("new-query-service"));

    // The drawer is QUERY-only: no REST/QUERY radio selector.
    expect(screen.queryByRole("radio", { name: /Query service/i })).not.toBeInTheDocument();

    await user.type(screen.getByLabelText(/Service ID/i), "diag-svc");
    await user.type(screen.getByLabelText(/Request URI/i), "/api/diag/**");
    await user.selectOptions(screen.getByLabelText(/Dialecto/i), "postgres");
    await user.type(screen.getByLabelText(/JDBC URL/i), "jdbc:postgresql://x/y");
    await user.type(screen.getByLabelText(/DB username/i), "u");
    await user.type(screen.getByLabelText(/Instance name/i), "diag");

    await user.click(screen.getByRole("button", { name: /Crear/i }));

    await waitFor(() => {
      const saveCall = fetchSpy.mock.calls.find(
        ([url, init]) =>
          typeof url === "string" &&
          url.includes("/sso-admin/microservice/save") &&
          (init as RequestInit | undefined)?.method === "POST",
      );
      expect(saveCall).toBeDefined();
    });

    const saveCall = fetchSpy.mock.calls.find(
      ([url]) => typeof url === "string" && url.includes("/sso-admin/microservice/save"),
    );
    const body = JSON.parse((saveCall![1] as RequestInit).body as string);
    expect(body.kind).toBe("QUERY");
    expect(body.serviceId).toBe("diag-svc");
    expect(body.dialect).toBe("postgres");
    expect(body.instanceName).toBe("diag");
  });
});
