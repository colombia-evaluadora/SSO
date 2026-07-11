import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ToastProvider } from "@/components/ui/Toast";
import { MicroservicesListPage } from "./MicroservicesListPage";
import { apiClient } from "@/api/client";
import type { MicroserviceResponse } from "@/api/types";

/**
 * The Microservicios page shows the REST table up top and the
 * QueryServicesSection (QUERY-kind CRUD/ops) below. These tests
 * assert the REST create flow, that the REST table itself still
 * filters out QUERY rows, and that QUERY services surface in the
 * section below rather than leaking into the REST table.
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
        <MicroservicesListPage />
      </ToastProvider>
    </QueryClientProvider>,
  );
}

function mkMs(over: Partial<MicroserviceResponse> = {}): MicroserviceResponse {
  return {
    id: 1,
    serviceId: "orders",
    description: "orders api",
    requestUri: "/api/orders/**",
    targetUriPath: "/v1",
    targetUrlHost: "orders.internal",
    targetUrlPort: "8080",
    createdDate: "2026-06-26T00:00:00Z",
    kind: "REST",
    dialect: null,
    jdbcUrl: null,
    dbUsername: null,
    dbPassword: null,
    poolSize: null,
    instanceName: null,
    ...over,
  };
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

describe("MicroservicesListPage — REST table + Query Services section", () => {
  let fetchSpy: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    apiClient.setAccessTokenGetter(() => "test-jwt");
    apiClient.setAuthFailureHandler(() => {});
    fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
  });
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("POSTs kind=REST to /sso-admin/microservice/save with the routing fields", async () => {
    fetchSpy.mockResolvedValueOnce(jsonResponse([])); // initial empty list
    fetchSpy.mockResolvedValue(jsonResponse(mkMs({ id: 1, serviceId: "diag-svc" }))); // save + refetch

    const user = userEvent.setup();
    renderPage();

    await user.click(screen.getByRole("button", { name: /Nuevo microservicio/i }));

    // REST-only drawer: no kind selector.
    expect(screen.queryByRole("radio", { name: /Query service/i })).not.toBeInTheDocument();

    await user.type(screen.getByLabelText(/Service ID/i), "diag-svc");
    await user.type(screen.getByLabelText(/Request URI/i), "/api/diag/**");
    await user.type(screen.getByLabelText(/Target host/i), "diag.internal");
    await user.type(screen.getByLabelText(/Target port/i), "9000");
    await user.type(screen.getByLabelText(/Target path/i), "/v1");

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
    expect(body.kind).toBe("REST");
    expect(body.serviceId).toBe("diag-svc");
    expect(body.targetUrlHost).toBe("diag.internal");
    expect(body.targetUrlPort).toBe("9000");
  });

  it("shows REST rows up top and QUERY services in the section below", async () => {
    const rest = mkMs({ id: 1, serviceId: "orders" });
    const query = mkMs({
      id: 2,
      serviceId: "q-oracle",
      kind: "QUERY",
      dialect: "oracle",
      jdbcUrl: "jdbc:oracle:thin:@db:1521/ORCLPDB1",
      instanceName: "oracle-dev",
    });
    fetchSpy.mockResolvedValue(jsonResponse([rest, query]));

    renderPage();

    // REST row renders in the Microservicios table.
    expect(await screen.findByText("orders")).toBeInTheDocument();
    // QUERY service now renders in the Query Services section below.
    expect(await screen.findByText("oracle-dev")).toBeInTheDocument();

    // ...and does NOT leak into the REST table above it.
    const restSection = screen
      .getByRole("heading", { name: "Microservicios" })
      .closest("section") as HTMLElement;
    expect(within(restSection).queryByText("q-oracle")).not.toBeInTheDocument();
    expect(within(restSection).queryByText("oracle-dev")).not.toBeInTheDocument();
  });
});
