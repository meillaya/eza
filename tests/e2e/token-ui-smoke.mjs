// API token UI smoke test: create form + scopes, one-time reveal + copy,
// list, bearer usage, revoke, and the one-time-only guarantee.
//
// Run from the repo root in the dev shell:
//   EZA_BASE=http://localhost:8093 node tests/e2e/token-ui-smoke.mjs
import { chromium } from "@playwright/test";

const BASE = process.env.EZA_BASE || "http://localhost:8093";
const passed = [];
const failed = [];
function check(name, condition, detail) {
  if (condition) {
    passed.push(name);
    console.log("PASS " + name + (detail ? " — " + detail : ""));
  } else {
    failed.push(name + (detail ? " — " + detail : ""));
    console.log("FAIL " + name + (detail ? " — " + detail : ""));
  }
}

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 1440, height: 950 } });
const page = await context.newPage();
const consoleErrors = [];
page.on("console", (message) => {
  if (message.type() === "error") consoleErrors.push(message.text());
});
page.on("pageerror", (error) => consoleErrors.push(String(error)));

const cdp = await context.newCDPSession(page);
await cdp.send("WebAuthn.enable", { enableUI: false });
await cdp.send("WebAuthn.addVirtualAuthenticator", {
  options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true },
});

const api = (path, options = {}) =>
  page.evaluate(
    async ({ path, options }) => {
      const csrf = document.cookie.split("; ").find((c) => c.startsWith("eza_csrf="))?.split("=")[1] || "";
      const headers = Object.assign({ "Content-Type": "application/json" }, options.headers || {});
      if ((options.method || "GET") !== "GET") headers["X-CSRF-Token"] = csrf;
      const response = await fetch(path, { ...options, headers });
      let body = null;
      try { body = await response.json(); } catch (_) {}
      return { status: response.status, body };
    },
    { path, options }
  );

try {
  await page.goto(BASE + "/setup", { waitUntil: "domcontentloaded" });
  await page.click("#passkey-setup");
  await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });
  await page.click("#continue");
  await page.waitForSelector(".topbar", { timeout: 30000 });
  await page.goto(BASE + "/account", { waitUntil: "domcontentloaded" });
  await page.waitForSelector(".token-form", { timeout: 20000 });
  check("API tokens panel present", (await page.locator("text=API tokens").count()) > 0);
  check("empty state", (await page.locator("text=No API tokens yet.").count()) > 0);

  // Create with read/write/capture scopes.
  await page.fill("#token-name", "E2E token");
  await page.locator(".scope-option", { hasText: "capture" }).locator("input").check();
  await page.getByRole("button", { name: "Create token", exact: true }).click();
  await page.waitForSelector(".token-reveal", { timeout: 20000 });
  const rawToken = (await page.locator(".token-secret").innerText()).trim();
  check("one-time reveal shown", rawToken.startsWith("eza_pat_"), rawToken.slice(0, 12) + "…");
  check(
    "one-time warning shown",
    (await page.locator(".token-reveal-title").innerText()).includes("shown only once")
  );

  await context.grantPermissions(["clipboard-read", "clipboard-write"], { origin: BASE });
  await page.getByRole("button", { name: "Copy token", exact: true }).click();
  await page.waitForTimeout(500);
  const clipboard = await page.evaluate(() => navigator.clipboard.readText().catch(() => ""));
  check("copy token writes clipboard", clipboard === rawToken, clipboard.slice(0, 12) + "…");

  // List shows the token metadata.
  const list = await api("/api/v1/tokens");
  const created = (list.body?.tokens || [])[0];
  check("token listed via api", Boolean(created), JSON.stringify(list.body || {}).slice(0, 120));
  check("token name stored", created?.name === "E2E token", String(created?.name));
  check(
    "token scopes stored",
    JSON.stringify(created?.scopes || []) === JSON.stringify(["read", "write", "capture"]),
    JSON.stringify(created?.scopes)
  );
  check("token is not revoked", created?.revoked_at === null || created?.revoked_at === undefined, String(created?.revoked_at));

  // The raw token works as a bearer for quick save (capture scope).
  const bearerSave = await page.evaluate(async (raw) => {
    const response = await fetch("/api/v1/quick-save", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + raw },
      body: JSON.stringify({ url: "https://example.com/token-smoke-" + Date.now(), title: "Token smoke" }),
    });
    return { status: response.status, body: await response.json().catch(() => null) };
  }, rawToken);
  check("bearer token quick-saves", [200, 201].includes(bearerSave.status), JSON.stringify(bearerSave));

  // One-time guarantee: reload hides the reveal.
  await page.goto(BASE + "/account", { waitUntil: "domcontentloaded" });
  await page.waitForSelector(".token-form", { timeout: 20000 });
  await page.waitForTimeout(600);
  check("reveal is one-time only", (await page.locator(".token-reveal").count()) === 0);
  check("token row visible after reload", (await page.locator(".cred", { hasText: "E2E token" }).count()) > 0);

  // Revoke from the UI.
  await page.locator('.cred:has-text("E2E token") button[title="Revoke token"]').click();
  await page.waitForFunction(
    () => [...document.querySelectorAll(".toast")].some((toast) => /Token revoked/.test(toast.textContent)),
    null,
    { timeout: 20000 }
  ).catch(() => {});
  await page.waitForTimeout(900);
  const revokedRow = await page.locator('.cred:has-text("E2E token")').innerText();
  check("revoked state shown in UI", /revoked/i.test(revokedRow), revokedRow.replace(/\n+/g, " ").slice(0, 100));
  const afterRevoke = await api("/api/v1/tokens");
  const revoked = (afterRevoke.body?.tokens || []).find((token) => token.name === "E2E token");
  check("revoked_at set on server", Boolean(revoked?.revoked_at), String(revoked?.revoked_at));

  // Revoked bearer is rejected.
  const revokedSave = await page.evaluate(async (raw) => {
    const response = await fetch("/api/v1/quick-save", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + raw },
      body: JSON.stringify({ url: "https://example.com/token-revoked-" + Date.now() }),
    });
    return { status: response.status };
  }, rawToken);
  check("revoked bearer rejected", revokedSave.status === 401, "status " + revokedSave.status);
} catch (error) {
  failed.push("unexpected error — " + (error && error.stack ? error.stack : String(error)));
} finally {
  await browser.close();
}

console.log("");
console.log("passed: " + passed.length + ", failed: " + failed.length);
if (consoleErrors.length) {
  console.log("console errors (" + consoleErrors.length + "):");
  for (const error of consoleErrors.slice(0, 10)) console.log("  " + error);
}
if (failed.length) {
  console.log("failures:");
  for (const failure of failed) console.log("  - " + failure);
  process.exit(1);
}
