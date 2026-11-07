/**
 * Visual QA + regression gate (plan todo 24) — harness e2e.
 *
 * Runs against the `visual-qa` project (port 8001, ui-e2e.db). The UI DB is
 * wiped at webServer boot, so this spec seeds its own bookmarks and a passkey
 * credential directly through the app DB (same pattern as
 * notes-editor.spec.ts) and authenticates via a REAL usernameless WebAuthn
 * ceremony through the CDP virtual authenticator.
 *
 * The suite is a screenshot pass over every surface, plus the virtualization
 * regression the plan demands: the grid renders exactly PAGE_SIZE (60) cards
 * and scrolling to the sentinel triggers fetchPage (a second page of cards
 * appears) — pinning that `content-visibility: auto` virtualization still
 * pages correctly when the corpus exceeds one page (the e2e DB seeds 130
 * "VisualQA Grid" bookmarks; the live 9k-row corpus behaves identically).
 *
 * Also checked: light+dark themes (prefers-color-scheme is emulated and the
 * computed --bg token is asserted to actually switch), keyboard navigation
 * (/ focus-search, Tab walk into the grid, k opens the quick switcher), the
 * mobile 600px breakpoint (single-column grid), the graph canvas, the quick
 * switcher palette, and /account.
 *
 * Every screenshot is written under test-results/visual-qa-shots/ — inside
 * the docker named `test-results` volume (mounted at /work/test-results,
 * gitignored). The CI step copies them out to .omo/evidence/task-24-shots/.
 * Like every other harness spec, an exact global result COUNT is never
 * asserted — other projects share ui-e2e.db, so assertions are scoped to
 * this spec's distinctive "VisualQA" fixtures.
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
const GRID_SEED_COUNT = 130;
/** Screenshots land in the docker named test-results volume (gitignored). */
const SHOTS_DIR = "test-results/visual-qa-shots";

type SeededVisualQa = {
  gridIds: number[];
  detailTarget: number;
  detailSource: number;
  graphHub: number;
};

/** Insert the fixture bookmarks into the UI DB (the server's own WAL DB). */
function seedVisualQa(): SeededVisualQa {
  const gridTitles = Array.from(
    { length: GRID_SEED_COUNT },
    (_, i) => `VisualQA Grid ${String(i + 1).padStart(3, "0")}`,
  );
  const code = `
import os, json
os.environ["BOOKMARKS_DB"] = "${UI_E2E_DB}"
from app import db
grid_ids = []
for i, t in enumerate(${JSON.stringify(gridTitles)}, start=1):
    grid_ids.append(db.insert_bookmark(url=f"https://vqa.example.org/g{i:03d}", title=t))
target = db.insert_bookmark(url="https://vqa.example.org/detail", title="VisualQA Detail Target")
source = db.insert_bookmark(url="https://vqa.example.org/source", title="VisualQA Detail Source")
prose = db.insert_bookmark(url="https://vqa.example.org/prose", title="VisualQA Prose Mention")
db.update_metadata(target, extracted_text="Extracted body of the VisualQA detail target. A full article paragraph that exercises the reader layout, wrapping across several lines in the reader panel.")
db.update_bookmark(target, note_body="A note about the target.\\n\\nSee [[VisualQA Detail Source]] for context.")
db.update_bookmark(source, note_body="See [[VisualQA Detail Target]] for the mapping table.")
db.update_bookmark(prose, note_body="The VisualQA Detail Target covers wikilink resolution in detail.")
hub = db.insert_bookmark(url="https://vqa.example.org/hub", title="VisualQA Graph Hub")
for i, name in enumerate(("One", "Two", "Three"), start=1):
    db.insert_bookmark(url=f"https://vqa.example.org/gt{i}", title=f"VisualQA Graph {name}")
db.update_bookmark(hub, note_body="[[VisualQA Graph One]] [[VisualQA Graph Two]] [[VisualQA Graph Three]]")
print(json.dumps({"gridIds": grid_ids, "detailTarget": target, "detailSource": source, "graphHub": hub}))
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
  return JSON.parse(stdout.trim().split("\n").pop() ?? "{}") as SeededVisualQa;
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

/** Sign in through the real WebAuthn ceremony and land on the authed grid. */
async function login(
  page: import("@playwright/test").Page,
  webauthn: import("./fixtures").WebAuthnState,
  credential: SeededCredential,
): Promise<void> {
  await addVirtualCredential(webauthn, credential);
  await page.goto("/");
  expect((await loginViaCeremony(page, credential.credentialId)).status).toBe(200);
  // The ceremony is fetch-based (no page reload): navigate again so the
  // session cookie takes effect and the authed grid actually renders.
  await page.goto("/");
  await expect(page.locator("#grid")).toBeVisible();
}

/** Capture a viewport screenshot into the test-results volume. */
async function shot(page: import("@playwright/test").Page, name: string): Promise<void> {
  await page.screenshot({ path: `${SHOTS_DIR}/${name}.png` });
}

let seeded: SeededVisualQa;
let credential: SeededCredential;

test.beforeAll(() => {
  seeded = seedVisualQa();
  credential = seedCredential(UI_E2E_DB, "/tmp/e2e-seed-visual-qa.json");
});

test("grid renders 60 cards and scrolling to the sentinel triggers fetchPage (virtualization intact)", async ({
  page,
  webauthn,
}) => {
  await login(page, webauthn, credential);
  const errors = collectErrors(page);
  const cards = page.locator("#grid .card");

  // PAGE_SIZE = 60; the sentinel sits below the fold so no auto-fetch yet.
  await expect(cards).toHaveCount(60);
  await expect(page.locator("#grid")).toHaveAttribute("data-exhausted", "false");

  // Scroll to the bottom: the IntersectionObserver fires fetchPage, which
  // appends the NEXT 60 cards — the grid now holds two pages.
  await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight));
  await expect(cards).toHaveCount(120);
  await expect(page.locator("#grid")).toHaveAttribute("data-exhausted", "false");

  // The light theme token (--bg #fafaf9) is the default rendering.
  const bg = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  expect(bg).toBe("rgb(250, 250, 249)");
  await shot(page, "grid-light");
  expect(errors).toEqual([]);
});

test("detail view renders extraction, notes and backlinks", async ({ page, webauthn }) => {
  await login(page, webauthn, credential);
  const errors = collectErrors(page);
  await page.goto(`/bookmark/${seeded.detailTarget}`);
  await expect(page.locator("#detail")).toBeVisible();

  // Extraction: the reader section shows the seeded extracted_text.
  await expect(page.locator("#reader .reader-text")).toContainText("Extracted body of the");
  // Notes: the note editor is prefilled with the seeded note.
  await expect(page.locator("#note")).toHaveValue(/VisualQA Detail Source/);
  // Backlinks: the linked source ([[…]]) and the prose mention both appear.
  await expect(page.locator("#backlinks .bl-linked .bl-source")).toHaveText(
    "VisualQA Detail Source",
  );
  await expect(page.locator("#backlinks .bl-unlinked .bl-source")).toHaveText(
    "VisualQA Prose Mention",
  );
  await shot(page, "detail-light");
  expect(errors).toEqual([]);
});

test("prefers-color-scheme dark switches the theme tokens (grid + detail screenshots)", async ({
  page,
  webauthn,
}) => {
  await login(page, webauthn, credential);
  const errors = collectErrors(page);
  await expect(page.locator("#grid .card")).toHaveCount(60);

  // Emulate the OS dark preference and reload: the --bg token must flip.
  await page.emulateMedia({ colorScheme: "dark" });
  await page.goto("/");
  const bgDark = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  expect(bgDark).toBe("rgb(14, 14, 16)");
  await shot(page, "grid-dark");

  await page.goto(`/bookmark/${seeded.detailTarget}`);
  await expect(page.locator("#detail")).toBeVisible();
  await shot(page, "detail-dark");
  expect(errors).toEqual([]);
});

test("graph canvas renders the hub neighborhood", async ({ page, webauthn }) => {
  await login(page, webauthn, credential);
  const errors = collectErrors(page);
  await page.goto(`/graph?seed=${seeded.graphHub}`);

  await expect(page.locator("#graph-canvas")).toHaveAttribute("data-rendered", "true");
  // Cytoscape draws into its own <canvas> elements inside the container.
  await expect(page.locator("#graph-canvas canvas")).not.toHaveCount(0);
  // Hub + 3 targets, 3 edges — deterministic: only THIS spec's fixtures link
  // the hub, so the neighborhood is exact even in the shared DB.
  await expect(page.locator("#graph-stats")).toHaveText(/4 nodes · 3 edges/);
  await shot(page, "graph-light");
  expect(errors).toEqual([]);
});

test("keyboard nav: / focuses search, Tab walks the topbar into the grid, k opens the switcher", async ({
  page,
  webauthn,
}) => {
  await login(page, webauthn, credential);
  const errors = collectErrors(page);
  await page.evaluate(() => {
    (document.activeElement as HTMLElement | null)?.blur?.();
  });

  // "/" focuses the search bar.
  await page.keyboard.press("/");
  await expect(page.locator("#search")).toBeFocused();

  // Tab walks the topbar in DOM order: search → +Add → the nav links (Inbox,
  // Graph, Dedup, Tags, AI tags, Maintenance) → + Save search → "all" chip →
  // first grid card. The topbar grew these links as features landed (dedup,
  // tag consolidation, AI tags, inbox), so the sequence tracks the live DOM.
  const topbarLinks = [
    'a.btn[href="/inbox"]',
    'a.btn[href="/graph"]',
    'a.btn[href="/dedup"]',
    'a.btn[href="/tags-cleanup"]',
    'a.btn[href="/tags-suggestions"]',
    'a.btn[href="/maintenance"]',
  ];
  await page.keyboard.press("Tab");
  await expect(page.locator("#add-btn")).toBeFocused();
  for (const selector of topbarLinks) {
    await page.keyboard.press("Tab");
    await expect(page.locator(selector)).toBeFocused();
  }
  await page.keyboard.press("Tab");
  await expect(page.locator("#save-search")).toBeFocused();
  await page.keyboard.press("Tab");
  await expect(page.locator('.chip[data-tag=""]')).toBeFocused();
  // …and the next Tab lands inside the grid on the first card link.
  await page.keyboard.press("Tab");
  await expect(page.locator("#grid .card .card-link").first()).toBeFocused();

  // "k" (body focus, no modifier) opens the quick switcher palette.
  await page.keyboard.press("k");
  const palette = page.locator("#quick-switcher");
  await expect(palette).toBeVisible();
  await shot(page, "qs-light");
  await page.keyboard.press("Escape");
  await expect(palette).toBeHidden();
  expect(errors).toEqual([]);
});

test("mobile 600px breakpoint renders a single-column grid", async ({ page, webauthn }) => {
  await page.setViewportSize({ width: 600, height: 800 });
  await login(page, webauthn, credential);
  const errors = collectErrors(page);
  await expect(page.locator("#grid .card")).toHaveCount(60);

  // At ≤600px the grid collapses to one column (style.css @media max-width:600px).
  const columns = await page.evaluate(
    () => getComputedStyle(document.querySelector("#grid")!).gridTemplateColumns.split(" ").length,
  );
  expect(columns).toBe(1);
  await shot(page, "grid-mobile");
  expect(errors).toEqual([]);
});

test("/account lists the passkey and the regenerate button", async ({ page, webauthn }) => {
  await login(page, webauthn, credential);
  const errors = collectErrors(page);
  await page.goto("/account");

  // The seeded passkey is listed (setup's own credential may also be present,
  // so assert at least one — never an exact count).
  await expect(page.locator("#credentials li").first()).toBeVisible();
  await expect(page.locator("#credentials li")).not.toHaveCount(0);
  await expect(page.locator("#regenerate")).toBeVisible();
  await shot(page, "account-light");
  expect(errors).toEqual([]);
});
