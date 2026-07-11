import { test, expect } from "@playwright/test";

/**
 * Happy-path: login → see the users list (with the seeded admin) →
 * logout → back at login.
 *
 * Assumes the seed has a user `admin` with password `admin` (the
 * default in the legacy sso-service schema). If the seed changes,
 * update the credentials here.
 */
test.describe("admin-ui happy path", () => {
  test("login -> users list -> logout", async ({ page }) => {
    // 1. Land on /admin/ unauthenticated -> SPA redirects to /login.
    await page.goto("/");
    await expect(page).toHaveURL(/\/login$/);

    // 2. Fill credentials + submit.
    await page.getByLabel(/Usuario/i).fill("admin");
    await page.getByLabel(/Contraseña/i).fill("admin");
    await page.getByRole("button", { name: /Entrar/i }).click();

    // 3. Redirect to /admin/users with the table.
    await expect(page).toHaveURL(/\/admin\/users$/);
    // The seeded admin row appears. Use a resilient selector —
    // any cell whose text is "admin" (username) on the users page.
    await expect(
      page.getByRole("cell", { name: "admin" }).first(),
    ).toBeVisible({ timeout: 10_000 });

    // 4. The access token lives ONLY in JS heap, never in storage.
    // If we ever regressed and started writing to localStorage,
    // this assertion catches it.
    const storage = await page.evaluate(() => ({
      local: JSON.stringify(window.localStorage),
      session: JSON.stringify(window.sessionStorage),
    }));
    expect(storage.local).toBe("{}");
    expect(storage.session).toBe("{}");

    // 5. The refresh cookie is HttpOnly — DevTools would still
    // show the cookie value to the user; this is intentional so
    // the SPA's client.ts can read its expiry if needed. We just
    // confirm the cookie is present and HttpOnly.
    const cookies = await page.context().cookies();
    const refresh = cookies.find((c) => c.name === "sso_refresh");
    expect(refresh).toBeTruthy();
    expect(refresh!.httpOnly).toBe(true);

    // 6. Logout -> back to /login, cookie cleared.
    await page.getByRole("button", { name: /Salir/i }).click();
    await expect(page).toHaveURL(/\/login$/);

    const cookiesAfter = await page.context().cookies();
    const refreshAfter = cookiesAfter.find((c) => c.name === "sso_refresh");
    // Either gone, or Max-Age=0 (we don't read attributes, just
    // check the cookie was wiped by the logout endpoint).
    if (refreshAfter) {
      expect(refreshAfter.expires).toBeLessThan(Date.now() / 1000 + 60);
    }
  });

  test("CSP: no inline scripts/styles", async ({ page }) => {
    // 1. Capture every console message — fail on CSP violation.
    const violations: string[] = [];
    page.on("console", (msg) => {
      if (msg.type() === "error" && /Content Security Policy/i.test(msg.text())) {
        violations.push(msg.text());
      }
    });

    await page.goto("/");
    // Wait for the login page to render (so the SPA's JS ran).
    await expect(page.getByLabel(/Usuario/i)).toBeVisible();
    expect(violations).toEqual([]);
  });
});
