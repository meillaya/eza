import { defineConfig, devices } from "@playwright/test";

/**
 * Reproducible browser e2e harness (plan todo 13). Adopts the five-file
 * contract from reproducible-e2e-browser-testing/e2e/README.md §1.4:
 *
 * - `baseURL` from PLAYWRIGHT_BASE_URL (fallback http://localhost:8000).
 * - A TWO-entry `webServer` array with DISTINCT ports (8000 = auth DB,
 *   8001 = ui DB). webServer entries have no native pre-step hook, so each
 *   command CHAINS its DB-glob delete into the shell string and then boots
 *   uvicorn through `uv run --frozen` — that is BOTH the sync-at-boot
 *   mechanism (uv syncs the lockfile into UV_PROJECT_ENVIRONMENT on first
 *   use) AND the uvicorn resolver (never depends on PATH).
 * - When PLAYWRIGHT_BASE_URL is set (Railway cron / external deployment),
 *   the webServer array is emptied entirely — the suite targets the
 *   external origin instead of booting servers.
 * - Projects are keyed to servers via PER-PROJECT use.baseURL; the `setup`
 *   project (first-run registration on 8001) is a dependency of the wave 3-4
 *   harness consumers, which share its storageState.
 * - workers: 1 — deterministic ordering (Railway cron convention §2.3).
 * - CI-aware retries.
 */

const PLAYWRIGHT_BASE_URL = process.env.PLAYWRIGHT_BASE_URL;

// Container-local venv so the harness never touches a bind-mounted .venv
// (the image's /work is the repo bind mount; a root-owned sync there would
// corrupt the host checkout's venv — the same class of trap as the
// Dockerfile bind-mount problem the contract calls out).
const UV_PROJECT_ENVIRONMENT = "/tmp/bookmarks-e2e-venv";

const webServer = PLAYWRIGHT_BASE_URL
  ? []
  : [
      {
        // Auth ceremony DB (8000): wiped at every boot by the chained rm.
        command:
          "rm -f /work/e2e/auth-e2e.db* && uv run --frozen uvicorn app.main:app --port 8000",
        url: "http://localhost:8000/health",
        reuseExistingServer: false,
        timeout: 120_000,
        env: {
          BOOKMARKS_DB: "/work/e2e/auth-e2e.db",
          PUBLIC_ORIGIN: "http://localhost:8000",
          SECRET_KEY: "e2e-auth-server-secret-key-0123456789abcdef",
          UV_PROJECT_ENVIRONMENT,
        },
      },
      {
        // UI DB (8001): first-run registration + all dependent consumers.
        command:
          "rm -f /work/e2e/ui-e2e.db* && uv run --frozen uvicorn app.main:app --port 8001",
        url: "http://localhost:8001/health",
        reuseExistingServer: false,
        timeout: 120_000,
        env: {
          BOOKMARKS_DB: "/work/e2e/ui-e2e.db",
          PUBLIC_ORIGIN: "http://localhost:8001",
          SECRET_KEY: "e2e-ui-server-secret-key-0123456789abcdef",
          UV_PROJECT_ENVIRONMENT,
        },
      },
    ];

export default defineConfig({
  testDir: "tests/e2e",
  workers: 1,
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? [["list"], ["html", { open: "never" }]] : [["list"]],
  use: {
    ...devices["Desktop Chrome"],
  },
  webServer,
  projects: [
    {
      // Auth ceremonies against the auth DB on 8000 (independent of setup).
      name: "auth",
      testMatch: "**/auth.spec.ts",
      use: { ...devices["Desktop Chrome"], baseURL: "http://localhost:8000" },
    },
    {
      // Smoke first: it asserts /setup is still the fresh 200 first-run page,
      // so it must run before the setup project claims the 8001 DB.
      name: "chromium-smoke",
      testMatch: "**/smoke.spec.ts",
      use: { ...devices["Desktop Chrome"], baseURL: "http://localhost:8001" },
    },
    {
      // First-run registration on 8001; saves storageState for dependents.
      name: "setup",
      testMatch: "**/setup.spec.ts",
      use: { ...devices["Desktop Chrome"], baseURL: "http://localhost:8001" },
    },
    {
      name: "notes-editor",
      testMatch: "**/notes-editor.spec.ts",
      use: { ...devices["Desktop Chrome"], baseURL: "http://localhost:8001" },
      dependencies: ["setup"],
      storageState: ".auth/ui-user.json",
    },
    {
      name: "backlinks",
      testMatch: "**/backlinks.spec.ts",
      use: { ...devices["Desktop Chrome"], baseURL: "http://localhost:8001" },
      dependencies: ["setup"],
      storageState: ".auth/ui-user.json",
    },
    {
      name: "graph",
      testMatch: "**/graph.spec.ts",
      use: { ...devices["Desktop Chrome"], baseURL: "http://localhost:8001" },
      dependencies: ["setup"],
      storageState: ".auth/ui-user.json",
    },
    {
      name: "quick-switcher",
      testMatch: "**/quick-switcher.spec.ts",
      use: { ...devices["Desktop Chrome"], baseURL: "http://localhost:8001" },
      dependencies: ["setup"],
      storageState: ".auth/ui-user.json",
    },
    {
      name: "visual-qa",
      testMatch: "**/visual-qa.spec.ts",
      use: { ...devices["Desktop Chrome"], baseURL: "http://localhost:8001" },
      dependencies: ["setup"],
      storageState: ".auth/ui-user.json",
    },
  ],
});
