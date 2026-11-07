/**
 * First-run registration on port 8001 (ui-e2e.db). Saves the resulting
 * session to `.auth/ui-user.json`, the storageState every dependent project
 * (notes-editor, backlinks, graph, quick-switcher, visual-qa) loads.
 *
 * This project MUST run before those dependents (declared via Playwright
 * project `dependencies`) and after `chromium-smoke` (which asserts /setup
 * is still the fresh first-run page on the same 8001 DB).
 */

import { test, expect, gotoStatus } from "./fixtures";

test("first-run registration on 8001 and saves storageState for dependents", async ({
  page,
  webauthn,
}) => {
  expect(await gotoStatus(page, "/setup")).toBe(200);
  await expect(page.locator("#register")).toBeVisible();

  // Real ceremony through the page's own button handler.
  await page.locator("#register").click();
  await expect(page.locator("#codes")).toBeVisible();
  await expect(page.locator("#codes")).not.toBeEmpty();

  // The registration opened a session; persist it for dependent projects.
  await page.context().storageState({ path: ".auth/ui-user.json" });

  // Sanity: the saved session is live.
  expect(await gotoStatus(page, "/")).toBe(200);
});
