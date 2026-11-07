/**
 * Backlinks panel + link-it affordance (plan todo 21) — harness e2e.
 *
 * Runs against the `backlinks` project (port 8001, ui-e2e.db). The UI DB is
 * wiped at webServer boot, so this spec seeds its own bookmarks and a passkey
 * credential directly through the app DB (same pattern as notes-editor.spec.ts)
 * and authenticates via a REAL usernameless WebAuthn ceremony through the CDP
 * virtual authenticator — it does not rely on the project-level storageState
 * (the harness gotcha documented in the notes-editor spec).
 *
 * Fixture graph: "Backlinks Field Guide" (the target) is linked from B's note
 * ("See [[Backlinks Field Guide]] …") and merely mentioned in prose in C's
 * note ("… the Backlinks Field Guide covers …") — so the panel must show B
 * under Linked mentions and C under Unlinked mentions. D has no mentions
 * anywhere (the empty-state case).
 *
 * Scenarios:
 *  1. with fixture data the panel shows BOTH sections (linked + unlinked).
 *  2. clicking Link on C's row rewrites the prose mention into [[Title]] via
 *     PATCH; after reload the mention has moved unlinked → linked.
 *  3. a bookmark with no mentions shows the empty state, no console errors.
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

const FIXTURES = {
  target: { url: "https://kb.example.org/backlinks", title: "Backlinks Field Guide" },
  linkedSource: { url: "https://kb.example.org/links", title: "Wikilink Mechanics" },
  unlinkedSource: { url: "https://kb.example.org/notes", title: "Note Taking at Scale" },
  lonely: { url: "https://kb.example.org/lonely", title: "Orphaned Reference" },
};

type SeededIds = Record<keyof typeof FIXTURES, number>;

/** Insert the fixture bookmarks into the UI DB, with note bodies set via
 * `db.update_bookmark` (which syncs the links table and the FTS index). */
function seedBacklinks(): SeededIds {
  const code = `
import os, json
os.environ["BOOKMARKS_DB"] = "${UI_E2E_DB}"
from app import db
f = ${JSON.stringify(FIXTURES)}
ids = {k: db.insert_bookmark(url=it["url"], title=it["title"]) for k, it in f.items()}
db.update_bookmark(ids["linkedSource"], note_body="See [[" + f["target"]["title"] + "]] for the mapping table.")
db.update_bookmark(ids["unlinkedSource"], note_body="The " + f["target"]["title"] + " covers wikilink resolution in detail.")
print(json.dumps(ids))
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
  return JSON.parse(stdout.trim().split("\n").pop() ?? "{}");
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

let ids: SeededIds;
let seed: SeededCredential;

test.beforeAll(() => {
  ids = seedBacklinks();
  seed = seedCredential(UI_E2E_DB, "/tmp/e2e-seed-backlinks.json");
});

test("with fixture data the panel shows both linked and unlinked sections", async ({
  page,
  webauthn,
}) => {
  await openDetail(page, webauthn, seed, ids.target);
  const errors = collectErrors(page);
  const panel = page.locator("#backlinks");

  await expect(panel.locator(".bl-section")).toHaveCount(2);
  await expect(panel.locator(".bl-heading").nth(0)).toHaveText(/Linked mentions/);
  await expect(panel.locator(".bl-heading").nth(1)).toHaveText(/Unlinked mentions/);
  // Linked rows are clickable and navigate to the source bookmark.
  await expect(panel.locator(".bl-linked .bl-source")).toHaveText(FIXTURES.linkedSource.title);
  await expect(panel.locator(".bl-linked .bl-source")).toHaveAttribute(
    "href",
    `/bookmark/${ids.linkedSource}`,
  );
  await expect(panel.locator(".bl-unlinked .bl-source")).toHaveText(FIXTURES.unlinkedSource.title);
  expect(errors).toEqual([]);
});

test("clicking Link rewrites the mention into [[Title]] and it moves to linked after reload", async ({
  page,
  webauthn,
}) => {
  await openDetail(page, webauthn, seed, ids.target);
  const errors = collectErrors(page);
  const panel = page.locator("#backlinks");

  const unlinkedRow = panel.locator(".bl-unlinked", { hasText: FIXTURES.unlinkedSource.title });
  await unlinkedRow.locator(".bl-link").click();

  // The mention leaves the unlinked section and appears under linked.
  await expect(panel.locator(".bl-unlinked")).toHaveCount(0);
  await expect(
    panel.locator(`.bl-linked .bl-source[href="/bookmark/${ids.unlinkedSource}"]`),
  ).toHaveText(FIXTURES.unlinkedSource.title);

  // And it stays linked after a reload (the source note now has [[Title]]).
  await page.reload();
  await expect(
    panel.locator(`.bl-linked .bl-source[href="/bookmark/${ids.unlinkedSource}"]`),
  ).toHaveText(FIXTURES.unlinkedSource.title);
  await expect(panel.locator(".bl-unlinked")).toHaveCount(0);
  expect(errors).toEqual([]);
});

test("a bookmark with no mentions shows the empty state without console errors", async ({
  page,
  webauthn,
}) => {
  await openDetail(page, webauthn, seed, ids.lonely);
  const errors = collectErrors(page);

  await expect(page.locator("#backlinks .bl-empty")).toContainText("No backlinks yet");
  expect(errors).toEqual([]);
});
