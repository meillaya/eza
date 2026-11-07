/**
 * Grid mutations carry the CSRF header (F2 fix) — harness e2e.
 *
 * The F2 final-wave reviewer found three fetch calls in static/app.js that
 * POST/DELETE without the X-CSRF-Token header the global middleware requires,
 * so in a real browser they always 403. This spec locks the fix at the browser
 * level: it drives the REAL UI flows (add modal, card × delete, import file
 * picker) against the 8001 ui-e2e.db and asserts the bookmark lands in the
 * grid — which only happens if the mutation got past the CSRF gate.
 *
 * Runs against the `add-bookmark` project (port 8001, ui-e2e.db). The UI DB is
 * wiped at webServer boot; like quick-switcher.spec.ts this spec seeds its own
 * passkey credential directly through the app DB and authenticates via a REAL
 * usernameless WebAuthn ceremony through the CDP virtual authenticator (it
 * does not rely on the project-level storageState — same harness gotcha).
 *
 * Scenarios:
 *  1. add-bookmark: open the Add modal, submit URL+tags → modal closes, the
 *     new card renders in the grid (asserted by href, unique to this spec).
 *  2. delete: click the card's × → the card is removed from the grid.
 *  3. import: setInputFiles on the import input with a Netscape bookmarks.html
 *     → the import alert reports ≥1 inserted, the page reloads, and the
 *     imported bookmark renders in the grid.
 * Every test also asserts zero console/page errors.
 */

import { execSync } from "node:child_process";
import {
  addVirtualCredential,
  expect,
  loginViaCeremony,
  seedCredential,
  test,
  type SeededCredential,
  E2E_WORKDIR,
} from "./fixtures";

const UI_E2E_DB = "/work/e2e/ui-e2e.db";

// Unique URLs so the card assertions never collide with other specs' seeds on
// the shared ui-e2e.db (the DB is wiped once at webServer boot, but every
// project in the run shares it).
const ADD_URL = "https://csrf-fix.example.org/added";
const DELETE_URL = "https://csrf-fix.example.org/added-delete";
const IMPORT_URL = "https://csrf-fix.example.org/imported";

/** Track every console error + page error so tests can assert zero. */
function collectErrors(page: import("@playwright/test").Page): string[] {
  const errors: string[] = [];
  page.on("console", (msg) => {
    if (msg.type() === "error") errors.push(msg.text());
  });
  page.on("pageerror", (err) => errors.push(String(err)));
  return errors;
}

/**
 * Sign in through the real WebAuthn ceremony and land on the authed grid.
 * #search carries autofocus, so blur it so the grid is the active target.
 */
async function openGrid(
  page: import("@playwright/test").Page,
  webauthn: import("./fixtures").WebAuthnState,
  seed: SeededCredential,
): Promise<void> {
  await addVirtualCredential(webauthn, seed);
  await page.goto("/");
  expect((await loginViaCeremony(page, seed.credentialId)).status).toBe(200);
  await page.goto("/");
  await expect(page.locator("#grid")).toBeVisible();
}

let seed: SeededCredential;

test.beforeAll(() => {
  seed = seedCredential(UI_E2E_DB, "/tmp/e2e-seed-csrf-fix.json");
});

test("add a bookmark through the UI modal (POST /api/bookmarks) and see it in the grid", async ({
  page,
  webauthn,
}) => {
  await openGrid(page, webauthn, seed);
  const errors = collectErrors(page);

  await page.locator("#add-btn").click();
  await expect(page.locator("#add-modal")).toBeVisible();
  await page.locator("#add-modal input[name=url]").fill(ADD_URL);
  await page.locator("#add-form").evaluate((form) => form.requestSubmit());

  // Success path: the modal closes and the fresh grid shows the new card —
  // only reachable if the POST carried the CSRF header (else the middleware
  // 403s and the handler alerts "Could not add bookmark").
  await expect(page.locator("#add-modal")).toBeHidden();
  const card = page.locator(`.card a.card-link[href="${ADD_URL}"]`).first();
  await expect(card).toBeVisible();
  expect(errors).toEqual([]);
});

test("delete a bookmark via the card × (DELETE /api/bookmarks/{id})", async ({
  page,
  webauthn,
}) => {
  await openGrid(page, webauthn, seed);
  const errors = collectErrors(page);

  // Seed the card through the UI first (the add flow already proves POST).
  await page.locator("#add-btn").click();
  await expect(page.locator("#add-modal")).toBeVisible();
  await page.locator("#add-modal input[name=url]").fill(DELETE_URL);
  await page.locator("#add-form").evaluate((form) => form.requestSubmit());
  const card = page.locator(`.card a.card-link[href="${DELETE_URL}"]`).first();
  await expect(card).toBeVisible();

  // Hover-targeting the × is what a user does; the delegation handler works
  // on the button directly regardless of hover state.
  await card.locator("xpath=ancestor::article").locator(".card-delete").click();
  await expect(card).toBeHidden();
  expect(errors).toEqual([]);
});

test("import a Netscape bookmarks.html via the file picker (POST /api/import)", async ({
  page,
  webauthn,
}) => {
  await openGrid(page, webauthn, seed);
  const errors = collectErrors(page);

  const netscapeHtml = `<!DOCTYPE NETSCAPE-Bookmark-file-1>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
    <DT><A HREF="${IMPORT_URL}" ADD_DATE="1700000000">CSRF Import One</A>
</DL><p>`;

  let imported = "";
  page.once("dialog", (dialog) => {
    imported = dialog.message();
    void dialog.accept();
  });
  await page.setInputFiles("#import-input", {
    name: "bookmarks.html",
    mimeType: "text/html",
    buffer: Buffer.from(netscapeHtml),
  });

  // The handler alerts `Imported N bookmarks. Reloading…` then reloads —
  // only reachable if the POST carried the CSRF header (else "Import failed").
  await expect
    .poll(async () => imported, { timeout: 5_000 })
    .toMatch(/^Imported ([1-9]\d*) bookmarks\. Reloading…$/);
  await expect(page.locator("#grid")).toBeVisible();
  const importedCard = page.locator(`.card a.card-link[href="${IMPORT_URL}"]`).first();
  await expect(importedCard).toBeVisible();
  expect(errors).toEqual([]);
});
