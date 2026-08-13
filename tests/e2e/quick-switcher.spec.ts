/**
 * Quick switcher palette (plan todo 22) — harness e2e.
 *
 * Runs against the `quick-switcher` project (port 8001, ui-e2e.db). The UI DB
 * is wiped at webServer boot, so this spec seeds its own bookmarks and a
 * passkey credential directly through the app DB (same pattern as
 * notes-editor.spec.ts) and authenticates via a REAL usernameless WebAuthn
 * ceremony through the CDP virtual authenticator — it does not rely on the
 * project-level storageState (the harness gotcha documented in the
 * notes-editor spec).
 *
 * The binding is plain `k` (no modifier) when NOT focused in an input —
 * Ctrl+K is reserved by Chrome's omnibox and Firefox's search bar, so page
 * JS can never intercept it. The footer hint says "press k". This spec
 * dispatches the ACTUAL chosen key.
 *
 * Scenarios:
 *  1. press `k` (body focused) → palette opens → type "rust" → two results →
 *     ArrowDown selects the second → Enter opens its detail page.
 *  2. typing `k` inside the #search input does NOT open the palette.
 *  3. the "/" focus-search shortcut still works (no conflict with `k`).
 *  4. Escape closes the palette.
 *  5. a query with no matches shows "add as new bookmark"; Enter opens the
 *     Add modal with the query prefilled as the URL.
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

/** Insert bookmarks into the UI DB (the server's own WAL database). */
function seedBookmarks(items: Array<{ url: string; title: string }>): number[] {
  const code = `
import os
os.environ["BOOKMARKS_DB"] = "${UI_E2E_DB}"
from app import db
print([db.insert_bookmark(url=it["url"], title=it["title"]) for it in ${JSON.stringify(items)}])
`;
  const b64 = Buffer.from(code).toString("base64");
  const stdout = execSync(
    `uv run --frozen python -c "import base64;exec(base64.b64decode('${b64}'))"`,
    {
      cwd: E2E_WORKDIR,
      env: {
        ...process.env,
        BOOKMARKS_DB: UI_E2E_DB,
        UV_PROJECT_ENVIRONMENT:
          process.env.UV_PROJECT_ENVIRONMENT ?? "/tmp/bookmarks-e2e-venv",
      },
      stdio: "pipe",
      encoding: "utf8",
    },
  );
  return JSON.parse(stdout.trim().split("\n").pop() ?? "[]");
}

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
 * #search carries autofocus, so blur it so plain-key bindings fire from
 * the document body (typing in an input must NOT open the palette).
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
  await page.evaluate(() => {
    (document.activeElement as HTMLElement | null)?.blur?.();
  });
}

/** Fixture bookmarks. Query "rust" matches exactly two of them (FTS5). */
const SEEDS = [
  { url: "https://switcher.example.org/rust-notes", title: "Rust Quick Notes" },
  { url: "https://switcher.example.org/rust-docs", title: "Rust Docs" },
  { url: "https://switcher.example.org/zig-notes", title: "Zig Notes" },
];

let ids: number[];
let seed: SeededCredential;

test.beforeAll(() => {
  ids = seedBookmarks(SEEDS);
  seed = seedCredential(UI_E2E_DB, "/tmp/e2e-seed-quick-switcher.json");
});

test("press k opens the palette; type, arrow, Enter opens the selected detail page", async ({
  page,
  webauthn,
}) => {
  await openGrid(page, webauthn, seed);
  const errors = collectErrors(page);
  const palette = page.locator("#quick-switcher");

  await page.keyboard.press("k");
  await expect(palette).toBeVisible();
  await expect(page.locator("#qs-input")).toBeFocused();

  await page.locator("#qs-input").fill("rust");
  const results = palette.locator("#qs-results");
  await expect(results.locator(".qs-item")).toHaveCount(2);
  await expect(results.locator(".qs-item.selected")).toHaveCount(1);

  // ArrowDown moves the selection to the second result; Enter opens it.
  await page.keyboard.press("ArrowDown");
  const selectedId = await results.locator(".qs-item.selected").getAttribute("data-id");
  expect(selectedId).not.toBeNull();
  await page.keyboard.press("Enter");

  await expect(page).toHaveURL(new RegExp(`/bookmark/${selectedId}$`));
  await expect(page.locator("#detail")).toBeVisible();
  expect(errors).toEqual([]);
});

test("typing in the search input does not open the palette", async ({
  page,
  webauthn,
}) => {
  await openGrid(page, webauthn, seed);
  const errors = collectErrors(page);
  const search = page.locator("#search");

  await search.click();
  await search.press("k");
  await expect(page.locator("#quick-switcher")).toBeHidden();
  await expect(search).toHaveValue("k");
  expect(errors).toEqual([]);
});

test("the / focus-shortcut still works without opening the palette", async ({
  page,
  webauthn,
}) => {
  await openGrid(page, webauthn, seed);
  const errors = collectErrors(page);

  await page.keyboard.press("/");
  await expect(page.locator("#search")).toBeFocused();
  await expect(page.locator("#quick-switcher")).toBeHidden();
  expect(errors).toEqual([]);
});

test("Escape closes the palette", async ({ page, webauthn }) => {
  await openGrid(page, webauthn, seed);
  const errors = collectErrors(page);
  const palette = page.locator("#quick-switcher");

  await page.keyboard.press("k");
  await expect(palette).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(palette).toBeHidden();
  expect(errors).toEqual([]);
});

test("no results shows add-as-new-bookmark which prefills the URL", async ({
  page,
  webauthn,
}) => {
  await openGrid(page, webauthn, seed);
  const errors = collectErrors(page);
  const palette = page.locator("#quick-switcher");
  const query = "zzznomatchxyzzy";

  await page.keyboard.press("k");
  await expect(palette).toBeVisible();
  await page.locator("#qs-input").fill(query);
  await expect(palette.locator(".qs-item.qs-create")).toBeVisible();
  await page.keyboard.press("Enter");

  await expect(page.locator("#add-modal")).toBeVisible();
  await expect(page.locator("#add-modal input[name=url]")).toHaveValue(query);
  expect(errors).toEqual([]);
});
