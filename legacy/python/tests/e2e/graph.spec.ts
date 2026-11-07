/**
 * Neighborhood graph view (plan todo 23) — harness e2e.
 *
 * Runs against the `graph` project (port 8001, ui-e2e.db). The UI DB is wiped
 * at webServer boot, so this spec seeds its own bookmarks (hub + 30 targets +
 * 8 second-hop extras + one isolated bookmark) and a passkey credential
 * directly through the app DB, then authenticates via a REAL usernameless
 * WebAuthn ceremony through the CDP virtual authenticator — the same pattern
 * as notes-editor.spec.ts.
 *
 * Scenarios:
 *  1. the graph canvas renders the seed's neighborhood (rendered flag,
 *     Cytoscape canvas element, node/edge counts in the stats badge).
 *  2. clicking a node navigates to that bookmark's detail page.
 *  3. an isolated bookmark shows a single-node graph with the empty state,
 *     no crash.
 *  4. perf smoke: the depth-2 neighborhood of a 30-target hub renders in
 *     under 2 seconds.
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
const HUB_TARGETS = 30;
const EXTRA_SOURCES = [1, 5, 10, 20]; // target indices whose notes link extras

/** The `window.cy` seam initGraphPage exposes (e2e-only, documented in app.js). */
type CySeam = {
  getElementById: (id: string) => {
    length: number;
    renderedPosition: () => { x: number; y: number };
  };
  container: () => HTMLElement;
};

type SeededGraph = {
  hub: number;
  target1: number;
  isolated: number;
  targetTitles: string[];
  extraTitles: string[];
};

/** Insert the fixture bookmarks into the UI DB, with note bodies set via
 * `db.update_bookmark` (which syncs the links table — the graph edges). */
function seedGraph(): SeededGraph {
  const targetTitles = Array.from(
    { length: HUB_TARGETS },
    (_, i) => `Graph Target ${String(i + 1).padStart(2, "0")}`,
  );
  const extraTitles = Array.from(
    { length: 8 },
    (_, i) => `Graph Extra ${String(i + 1).padStart(2, "0")}`,
  );
  const code = `
import os, json
os.environ["BOOKMARKS_DB"] = "${UI_E2E_DB}"
from app import db
hub = db.insert_bookmark(url="https://graph.example/hub", title="Graph Hub")
targets = []
for i, t in enumerate(${JSON.stringify(targetTitles)}, start=1):
    targets.append(db.insert_bookmark(url=f"https://graph.example/t{i:02d}", title=t))
extras = []
for i, t in enumerate(${JSON.stringify(extraTitles)}, start=1):
    extras.append(db.insert_bookmark(url=f"https://graph.example/e{i:02d}", title=t))
db.update_bookmark(hub, note_body=" ".join(f"[[{t}]]" for t in ${JSON.stringify(targetTitles)}))
for pair_idx, src_idx in enumerate(${JSON.stringify(EXTRA_SOURCES)}):
    note = " ".join(f"[[{t}]]" for t in ${JSON.stringify(extraTitles)}[pair_idx * 2:pair_idx * 2 + 2])
    db.update_bookmark(targets[src_idx - 1], note_body=note)
iso = db.insert_bookmark(url="https://graph.example/iso", title="Graph Isolated")
print(json.dumps({"hub": hub, "target1": targets[0], "isolated": iso}))
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
  const ids = JSON.parse(stdout.trim().split("\n").pop() ?? "{}");
  return { ...ids, targetTitles, extraTitles };
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

/** Sign in through the real WebAuthn ceremony. */
async function login(
  page: import("@playwright/test").Page,
  webauthn: import("./fixtures").WebAuthnState,
  seed: SeededCredential,
): Promise<void> {
  await addVirtualCredential(webauthn, seed);
  await page.goto("/");
  expect((await loginViaCeremony(page, seed.credentialId)).status).toBe(200);
}

/** Viewport coordinates of a rendered Cytoscape node (via the window.cy seam). */
async function nodeViewportPosition(
  page: import("@playwright/test").Page,
  id: number,
): Promise<{ x: number; y: number } | null> {
  return page.evaluate((nodeId) => {
    const cy = (window as unknown as { cy?: CySeam }).cy;
    if (!cy) return null;
    const node = cy.getElementById(String(nodeId));
    if (node.length === 0) return null;
    const p = node.renderedPosition();
    const rect = cy.container().getBoundingClientRect();
    return { x: rect.left + p.x, y: rect.top + p.y };
  }, id);
}

let seeded: SeededGraph;
let credential: SeededCredential;

test.beforeAll(() => {
  seeded = seedGraph();
  credential = seedCredential(UI_E2E_DB, "/tmp/e2e-seed-graph.json");
});

test("renders the seed's neighborhood with edges and no console errors", async ({
  page,
  webauthn,
}) => {
  await login(page, webauthn, credential);
  const errors = collectErrors(page);
  await page.goto(`/graph?seed=${seeded.hub}`);
  await expect(page.locator("#graph-canvas")).toHaveAttribute("data-rendered", "true");
  // Cytoscape draws into its own <canvas> elements inside the container.
  await expect(page.locator("#graph-canvas canvas")).not.toHaveCount(0);
  // Depth 1: hub + 30 targets, 30 edges.
  await expect(page.locator("#graph-stats")).toHaveText(/31 nodes · 30 edges/);
  expect(errors).toEqual([]);
});

test("clicking a node navigates to that bookmark's detail page", async ({
  page,
  webauthn,
}) => {
  await login(page, webauthn, credential);
  const errors = collectErrors(page);
  await page.goto(`/graph?seed=${seeded.hub}`);
  await expect(page.locator("#graph-canvas")).toHaveAttribute("data-rendered", "true");

  const pos = await nodeViewportPosition(page, seeded.target1);
  expect(pos).not.toBeNull();
  await page.mouse.click(pos!.x, pos!.y);
  await expect(page).toHaveURL(new RegExp(`/bookmark/${seeded.target1}`));
  await expect(page.locator("#detail")).toBeVisible();
  expect(errors).toEqual([]);
});

test("an isolated bookmark shows a single-node graph with the empty state and no crash", async ({
  page,
  webauthn,
}) => {
  await login(page, webauthn, credential);
  const errors = collectErrors(page);
  await page.goto(`/graph?seed=${seeded.isolated}`);

  await expect(page.locator("#graph-canvas")).toHaveAttribute("data-rendered", "true");
  await expect(page.locator("#graph-stats")).toHaveText(/1 node · 0 edges/);
  await expect(page.locator("#graph-empty")).toBeVisible();
  await expect(page.locator("#graph-empty")).toContainText("isn't linked to anything yet");
  expect(errors).toEqual([]);
});

test("perf smoke: depth-2 neighborhood of the hub renders in under 2 seconds", async ({
  page,
  webauthn,
}) => {
  await login(page, webauthn, credential);
  const errors = collectErrors(page);
  const started = Date.now();
  await page.goto(`/graph?seed=${seeded.hub}&depth=2`);
  await page.waitForSelector("#graph-canvas[data-rendered='true']", { timeout: 2000 });
  const elapsed = Date.now() - started;
  // Depth 2 adds the 8 extras the four target notes link: 39 nodes / 38 edges.
  await expect(page.locator("#graph-stats")).toHaveText(/39 nodes · 38 edges/);
  console.log(`graph perf: depth-2 neighborhood rendered in ${elapsed}ms`);
  expect(elapsed).toBeLessThan(2000);
  expect(errors).toEqual([]);
});
