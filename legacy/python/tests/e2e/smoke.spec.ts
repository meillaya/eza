/**
 * Minimal chromium smoke against port 8001 (ui-e2e.db, fresh at webServer
 * boot). Runs BEFORE the setup project claims that DB, so /setup is still the
 * unauthenticated first-run page here.
 */

import { test, expect, gotoStatus } from "./fixtures";

test("unauthenticated GET / returns the login page (401)", async ({ page }) => {
  expect(await gotoStatus(page, "/")).toBe(401);
  await expect(page.locator("h1")).toHaveText("Bookmarks");
  await expect(page.locator("#login")).toBeVisible();
});

test("/health is 200 and open", async ({ request }) => {
  const resp = await request.get("/health");
  expect(resp.status()).toBe(200);
});

test("/setup serves the first-run page while no credential exists", async ({ page }) => {
  expect(await gotoStatus(page, "/setup")).toBe(200);
  await expect(page.locator("#register")).toBeVisible();
});
