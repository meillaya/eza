import { chromium } from "@playwright/test";
const BASE = process.env.EZA_BASE || "http://localhost:8101";
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();
const page = await context.newPage();
const cdp = await context.newCDPSession(page);
await cdp.send("WebAuthn.enable", { enableUI: false });
await cdp.send("WebAuthn.addVirtualAuthenticator", { options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true } });
await page.goto(BASE + "/setup", { waitUntil: "networkidle" });
await page.fill("#username", process.env.EZA_TEST_USER || "e2e");
await page.fill("#password", process.env.EZA_TEST_PASSWORD || "e2e-password-123");
await page.fill("#confirm-password", process.env.EZA_TEST_PASSWORD || "e2e-password-123");
await page.click("#password-setup");
await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });
async function api(path, options = {}) {
  return page.evaluate(async ({ path, options }) => {
    const csrf = document.cookie.split("; ").find((c) => c.startsWith("eza_csrf="))?.split("=")[1] || "";
    const headers = { ...(options.headers || {}) };
    if (options.method && options.method !== "GET") headers["X-CSRF-Token"] = csrf;
    const start = performance.now();
    const response = await fetch(path, { ...options, headers });
    const text = await response.text();
    let body = null; try { body = JSON.parse(text); } catch { body = text.slice(0, 160); }
    return { status: response.status, body, ms: Math.round(performance.now() - start), headers: Object.fromEntries(response.headers.entries()) };
  }, { path, options });
}
for (const url of ["https://www.haskell.org/ghcup/", "https://www.haskell.org/cabal/"]) {
  const save = await api("/api/v1/quick-save", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url }) });
  console.log("save", url, save.status, save.ms + "ms", save.body);
  await page.waitForTimeout(7000);
  const detail = await api("/api/v1/bookmarks/" + save.body.id);
  console.log("detail", detail.status, detail.body?.title, "favicon", detail.body?.favicon_url, "state", detail.body?.enrich_state);
  const icon = await api(detail.body?.favicon_url || "/assets/favicon-fallback.svg");
  console.log("icon", icon.status, icon.headers["content-type"]);
}
const dup = await api("/api/v1/quick-save", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: "https://www.haskell.org/ghcup/" }) });
console.log("duplicate", dup.status, dup.body);
await browser.close();
