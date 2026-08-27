import { test, expect } from "@playwright/test";

/**
 * Smoke test para la búsqueda extendida (uuid/tipo/path) y el nuevo
 * select de filtro por método HTTP en el Queries Catalog.
 */
test.describe("query catalog search + method filter", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/");
    await expect(page.getByLabel(/Email/i)).toBeVisible({ timeout: 15_000 });
    await page.getByLabel(/Email/i).fill("admin@example.com");
    await page.getByLabel(/Contraseña/i).fill("ChangeMe-Now-Please-123!");
    await page.getByRole("button", { name: /Entrar/i }).click();
    await page.waitForURL(/\/admin\/(?!login)/, { timeout: 15_000 });
  });

  test("searching by path template filters the table", async ({ page }) => {
    await page.goto("/admin/query-catalog");
    const search = page.getByPlaceholder(/Buscar por UUID, tipo o path/i);
    await expect(search).toBeVisible({ timeout: 10_000 });
    // El catálogo real tiene 100+ filas — espera a que termine de
    // cargar (el estado "Cargando…" desaparece) antes de contar.
    await expect(page.getByRole("status", { name: /Cargando/i })).toHaveCount(0, {
      timeout: 15_000,
    });
    await expect(page.getByRole("row").first()).toBeVisible({ timeout: 10_000 });

    const rowsBefore = await page.getByRole("row").count();
    expect(rowsBefore).toBeGreaterThan(1);

    // Path template conocido, sembrado en el catálogo real.
    await search.fill("periodo-evaluacion");
    await expect(page.getByText("q-msntdig0-ue2q6veu")).toBeVisible();

    const rowsAfter = await page.getByRole("row").count();
    expect(rowsAfter).toBeLessThan(rowsBefore);
  });

  test("method select filters rows to the chosen HTTP verb", async ({ page }) => {
    await page.goto("/admin/query-catalog");
    const select = page.getByTestId("method-filter");
    await expect(select).toBeVisible({ timeout: 10_000 });
    await expect(page.getByRole("status", { name: /Cargando/i })).toHaveCount(0, {
      timeout: 15_000,
    });
    await expect(page.getByRole("row").first()).toBeVisible({ timeout: 10_000 });

    const rowsBefore = await page.getByRole("row").count();
    await select.selectOption("GET");
    const rowsAfterGet = await page.getByRole("row").count();
    expect(rowsAfterGet).toBeLessThan(rowsBefore);
    expect(rowsAfterGet).toBeGreaterThan(1);

    // Every visible data row's method badge should read GET.
    const methodBadges = page.locator('[data-testid^="query-path-template-"] >> text=GET');
    expect(await methodBadges.count()).toBeGreaterThan(0);

    await select.selectOption("");
    const rowsAfterReset = await page.getByRole("row").count();
    expect(rowsAfterReset).toBe(rowsBefore);
  });
});
