import { test, expect } from "@playwright/test";

/**
 * V81 — smoke test para la sección "Restricciones" del formulario de
 * queries: abrir la modal de un placeholder :BODY.* numérico y de
 * uno de texto, cambiar las reglas, guardar la query y verificar que
 * persisten al reabrir.
 *
 * Corre contra el stack Docker local (api-gateway sirviendo el SPA
 * en :8080/admin/), con las imágenes reconstruidas para esta rama —
 * ver BASE_URL en playwright.config.ts.
 */
test.describe("query param constraints", () => {
  test.beforeEach(async ({ page }) => {
    page.on("response", (res) => {
      if (res.url().includes("/auth/login")) {
        console.log("LOGIN RESPONSE", res.status());
      }
    });
    page.on("console", (msg) => console.log("BROWSER", msg.type(), msg.text()));
    await page.goto("/");
    await expect(page.getByLabel(/Email/i)).toBeVisible({ timeout: 15_000 });
    await page.getByLabel(/Email/i).fill("admin@example.com");
    await page.getByLabel(/Contraseña/i).fill("ChangeMe-Now-Please-123!");
    await page.getByRole("button", { name: /Entrar/i }).click();
    await page.waitForURL(/\/admin\/(?!login)/, { timeout: 15_000 });
  });

  test("editar restricciones numéricas y de texto en una query existente", async ({ page }) => {
    await page.goto("/admin/query-catalog");

    // La búsqueda filtra por uuid — usamos el uuid conocido de la
    // query 33 (/periodo-evaluacion) sembrada con restricciones.
    const search = page.getByPlaceholder(/buscar/i).first();
    await search.fill("q-msntdig0-ue2q6veu");

    const row = page.getByRole("row", { name: /q-msntdig0-ue2q6veu/i });
    await expect(row).toBeVisible({ timeout: 10_000 });
    await row.getByRole("button", { name: /editar/i }).click();

    // El drawer abre con el SQL ya cargado; la sección "Tipos de
    // parámetros" detecta los placeholders y muestra la columna
    // "Restricciones" con un botón por cada :BODY.* numérico o de
    // texto.
    await expect(page.getByText("Tipos de parámetros")).toBeVisible();

    const codigoRow = page.locator("tr", { hasText: ":BODY.CODIGO" });
    await expect(codigoRow).toBeVisible();
    // Ya tiene reglas sembradas por SQL directo — el botón debe
    // mostrar el estado "Editado".
    await expect(codigoRow.getByRole("button", { name: /Editado/i })).toBeVisible();
    await codigoRow.getByRole("button", { name: /Editado/i }).click();

    // Modal de texto: numericText + min/max length. Los valores
    // sembrados no se hardcodean acá — el test es idempotente
    // (corre repetidas veces contra el mismo catálogo) así que lee
    // lo que haya, lo cambia a algo distinto, verifica que persiste,
    // y al final restaura el valor original.
    await expect(page.getByText("Restricciones — :BODY.CODIGO")).toBeVisible();
    const numericTextCheckbox = page.getByLabel(/enteramente numérico/i);
    await expect(numericTextCheckbox).toBeChecked();
    const minInput = page.getByLabel(/Mínimo de caracteres/i);
    const maxInput = page.getByLabel(/Máximo de caracteres/i);
    await expect(minInput).not.toHaveValue("");
    const originalMax = await maxInput.inputValue();
    const changedMax = String(Number(originalMax) + 1);
    await maxInput.fill(changedMax);
    await page.getByRole("button", { name: "Listo" }).click();

    // Modal numérica: onlyPositive + maxDigits en BODY.PORCENTAJE.
    const porcentajeRow = page.locator("tr", { hasText: ":BODY.PORCENTAJE" });
    await porcentajeRow.getByRole("button", { name: /Editado/i }).click();
    await expect(page.getByText("Restricciones — :BODY.PORCENTAJE")).toBeVisible();
    const onlyPositiveCheckbox = page.getByLabel(/sólo admite números positivos/i);
    await expect(onlyPositiveCheckbox).toBeChecked();
    const maxDigitsInput = page.getByLabel(/Máximo de cifras significativas/i);
    const originalMaxDigits = await maxDigitsInput.inputValue();
    const changedMaxDigits = String(Number(originalMaxDigits) + 1);
    await maxDigitsInput.fill(changedMaxDigits);
    await page.getByRole("button", { name: "Listo" }).click();

    // Guardar y verificar toast de éxito. El submit dispara PUT
    // /query/update y luego invalida (refetch async) la lista — se
    // espera el refetch de getQueries explícitamente antes de
    // reabrir, para no leer datos todavía viejos del cache.
    const refetchAfterSave = page.waitForResponse(
      (res) => res.url().includes("/query/getQueries") && res.request().method() === "GET",
    );
    await page.getByRole("button", { name: /Guardar cambios/i }).click();
    await expect(page.getByText(/Query actualizado/i)).toBeVisible({ timeout: 10_000 });
    await refetchAfterSave;

    // Reabrir y confirmar que los cambios persistieron.
    await row.getByRole("button", { name: /editar/i }).click();
    await expect(page.getByText("Tipos de parámetros")).toBeVisible();
    const codigoRow2 = page.locator("tr", { hasText: ":BODY.CODIGO" });
    await codigoRow2.getByRole("button", { name: /Editado/i }).click();
    await expect(page.getByLabel(/Máximo de caracteres/i)).toHaveValue(changedMax);
    // Restaura el valor original para que el próximo run vea el
    // mismo estado de partida.
    await page.getByLabel(/Máximo de caracteres/i).fill(originalMax);
    await page.getByRole("button", { name: "Listo" }).click();

    const porcentajeRow2 = page.locator("tr", { hasText: ":BODY.PORCENTAJE" });
    await porcentajeRow2.getByRole("button", { name: /Editado/i }).click();
    await expect(page.getByLabel(/Máximo de cifras significativas/i)).toHaveValue(
      changedMaxDigits,
    );
    await page.getByLabel(/Máximo de cifras significativas/i).fill(originalMaxDigits);
    await page.getByRole("button", { name: "Listo" }).click();

    await page.getByRole("button", { name: /Guardar cambios/i }).click();
    await expect(page.getByText(/Query actualizado/i)).toBeVisible({ timeout: 10_000 });
  });

  test("el botón Restricciones sólo aparece en :BODY.* numéricos o de texto", async ({ page }) => {
    await page.goto("/admin/query-catalog");
    const search = page.getByPlaceholder(/buscar/i).first();
    await search.fill("q-msntdig0-ue2q6veu");
    const row = page.getByRole("row", { name: /q-msntdig0-ue2q6veu/i });
    await expect(row).toBeVisible({ timeout: 10_000 });
    await row.getByRole("button", { name: /editar/i }).click();

    await expect(page.getByText("Tipos de parámetros")).toBeVisible();

    // :BODY.FECHA_FIN es DATE — ni numérico ni texto en el sentido
    // de estas reglas, así que su celda de Restricciones muestra "—".
    const fechaFinRow = page.locator("tr", { hasText: ":BODY.FECHA_FIN" });
    if (await fechaFinRow.count()) {
      await expect(fechaFinRow.getByRole("button", { name: /Configurar|Editado/i })).toHaveCount(0);
    }
  });
});
