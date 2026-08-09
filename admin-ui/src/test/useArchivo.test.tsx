import { describe, expect, it, vi, beforeEach, afterEach } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { useArchivoUrl } from "@/hooks/useArchivo";
import { filesApi } from "@/api/endpoints";

vi.mock("@/api/endpoints", () => ({
  filesApi: { descargar: vi.fn() },
}));

/**
 * Lo que importa de este hook es la gestión del object URL:
 * {@code URL.createObjectURL} reserva memoria que el navegador NO
 * libera al desmontar. Si no se revoca a mano, una tabla que pinta
 * firmas va acumulando blobs vivos en cada recorrido.
 */
describe("useArchivoUrl", () => {
  const createObjectURL = vi.fn(() => "blob:objeto-1");
  const revokeObjectURL = vi.fn();

  beforeEach(() => {
    vi.stubGlobal("URL", { ...URL, createObjectURL, revokeObjectURL });
    createObjectURL.mockClear();
    revokeObjectURL.mockClear();
    vi.mocked(filesApi.descargar).mockReset();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  function wrapper({ children }: { children: ReactNode }) {
    const client = new QueryClient({
      defaultOptions: { queries: { retry: false } },
    });
    return <QueryClientProvider client={client}>{children}</QueryClientProvider>;
  }

  it("descarga el binario y expone su object URL", async () => {
    const blob = new Blob(["bytes"], { type: "image/png" });
    vi.mocked(filesApi.descargar).mockResolvedValue(blob);

    const { result } = renderHook(() => useArchivoUrl(42), { wrapper });

    await waitFor(() => expect(result.current.url).toBe("blob:objeto-1"));
    expect(filesApi.descargar).toHaveBeenCalledWith(42);
    expect(createObjectURL).toHaveBeenCalledWith(blob);
  });

  it("revoca el object URL al desmontar", async () => {
    vi.mocked(filesApi.descargar).mockResolvedValue(new Blob(["x"]));

    const { result, unmount } = renderHook(() => useArchivoUrl(42), { wrapper });
    await waitFor(() => expect(result.current.url).not.toBeNull());

    unmount();

    expect(revokeObjectURL).toHaveBeenCalledWith("blob:objeto-1");
  });

  /**
   * Sin id no hay descarga. Es el caso de una fila cuyo
   * {@code fk_tarchivo} es NULL — frecuente, y pedirle al servidor
   * {@code /files/download/0} sólo produce un 404 inútil.
   */
  it("no descarga nada cuando el id es null o cero", () => {
    const { result } = renderHook(() => useArchivoUrl(null), { wrapper });

    expect(filesApi.descargar).not.toHaveBeenCalled();
    expect(result.current.url).toBeNull();
    expect(result.current.isLoading).toBe(false);

    renderHook(() => useArchivoUrl(0), { wrapper });
    expect(filesApi.descargar).not.toHaveBeenCalled();
  });

  it("propaga el error sin dejar URL", async () => {
    vi.mocked(filesApi.descargar).mockRejectedValue(new Error("404"));

    const { result } = renderHook(() => useArchivoUrl(7), { wrapper });

    await waitFor(() => expect(result.current.error).toBeTruthy());
    expect(result.current.url).toBeNull();
    expect(createObjectURL).not.toHaveBeenCalled();
  });
});
