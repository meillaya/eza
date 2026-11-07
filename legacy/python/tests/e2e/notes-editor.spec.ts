/**
 * Notes editor + wikilink autocomplete (plan todo 20) — harness e2e.
 *
 * Runs against the `notes-editor` project (port 8001, ui-e2e.db). The UI DB
 * is wiped at webServer boot, so this spec seeds its own bookmarks and a
 * passkey credential directly through the app DB (same pattern as
 * `seedCredential` in the fixtures), then obtains its session the same way
 * auth.spec.ts does: a REAL usernameless WebAuthn ceremony through the CDP
 * virtual authenticator — it does not rely on storageState timing.
 *
 * Scenarios:
 *  1. type a note, Ctrl+S, reload — content persists.
 *  2. `[[` opens the autocomplete dropdown; completing inserts `[[Title|]]`.
 *  3. an unmatched `[[` query shows "No matches" without crashing.
 *  4. beforeunload warns when navigating away with unsaved edits.
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

/** Sign in through the real WebAuthn ceremony and land on the detail page. */
async function openDetail(
  page: import("@playwright/test").Page,
  webauthn: import("./fixtures").WebAuthnState,
  seed: SeededCredential,
  bookmarkId: number,
): Promise<void> {
  await addVirtualCredential(webauthn, seed);
  await page.goto("/");
  expect((await loginViaCeremony(page, seed.credentialId)).status).toBe(200);
  await page.goto(`/bookmark/${bookmarkId}`);
  await expect(page.locator("#note")).toBeVisible();
}

let primaryId = 0;
let seed: SeededCredential;

test.beforeAll(() => {
  const ids = seedBookmarks([
    { url: "https://notes.example.org/post", title: "Async Rust Notes" },
    { url: "https://example.org/wiki/rust", title: "Rust Wiki" },
    { url: "https://example.org/wiki/zig", title: "Zig Wiki" },
    { url: "https://example.org/tools", title: "Dev Tools" },
  ]);
  primaryId = ids[0];
  seed = seedCredential(UI_E2E_DB, "/tmp/e2e-seed-notes.json");
});

test("types a note, Ctrl+S saves, and the note persists after reload", async ({
  page,
  webauthn,
}) => {
  await openDetail(page, webauthn, seed, primaryId);
  const errors = collectErrors(page);
  const note = page.locator("#note");
  const noteText = "A note about async rust.\n\nSaved via Ctrl+S.";

  await note.fill(noteText);
  await page.keyboard.press("Control+s");
  await expect(page.locator("#save-status")).toHaveText("Saved");

  await page.reload();
  await expect(page.locator("#note")).toHaveValue(noteText);
  expect(errors).toEqual([]);
});

test("[[ opens the autocomplete dropdown and completing inserts [[Title|]]", async ({
  page,
  webauthn,
}) => {
  await openDetail(page, webauthn, seed, primaryId);
  const errors = collectErrors(page);
  const note = page.locator("#note");
  const dropdown = page.locator("#wikilink-autocomplete");

  await note.fill("See ");
  await note.pressSequentially("[[", { delay: 30 });
  await expect(dropdown).toBeVisible();
  await expect(dropdown.locator(".ac-hint")).toContainText("Start typing");

  await note.pressSequentially("rust", { delay: 30 });
  await expect(dropdown.locator(".ac-item")).toHaveCount(2);

  await page.keyboard.press("Enter");
  await expect(note).toHaveValue("See [[Rust Wiki|]]");
  expect(errors).toEqual([]);
});

test("an unmatched [[ query shows No matches without crashing", async ({
  page,
  webauthn,
}) => {
  await openDetail(page, webauthn, seed, primaryId);
  const errors = collectErrors(page);
  const note = page.locator("#note");
  const dropdown = page.locator("#wikilink-autocomplete");

  await note.fill("See ");
  await note.pressSequentially("[[zzz-no-such-thing", { delay: 30 });
  await expect(dropdown).toBeVisible();
  await expect(dropdown.locator(".ac-hint")).toHaveText("No matches");
  expect(errors).toEqual([]);
});

test("beforeunload warns when navigating away with unsaved edits", async ({
  page,
  webauthn,
}) => {
  await openDetail(page, webauthn, seed, primaryId);
  const note = page.locator("#note");
  await note.fill("unsaved note");

  const dialogPromise = page.waitForEvent("dialog");
  await page.evaluate(() => {
    setTimeout(() => {
      window.location.href = "/";
    }, 0);
  });
  const dialog = await dialogPromise;
  expect(dialog.type()).toBe("beforeunload");
  await dialog.dismiss();
});
