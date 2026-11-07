import { chromium } from "@playwright/test";
const BASE = process.env.EZA_BASE || "http://localhost:8095";
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();
const page = await context.newPage();
const cdp = await context.newCDPSession(page);
await cdp.send("WebAuthn.enable", { enableUI: false });
await cdp.send("WebAuthn.addVirtualAuthenticator", { options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true } });
await page.goto(BASE + "/setup", { waitUntil: "networkidle" });
await page.click("#passkey-setup");
await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });
async function api(path, options = {}) {
  return page.evaluate(async ({ path, options }) => {
    const csrf = document.cookie.split("; ").find((c) => c.startsWith("eza_csrf="))?.split("=")[1] || "";
    const headers = { ...(options.headers || {}) };
    if (options.method && options.method !== "GET") headers["X-CSRF-Token"] = csrf;
    const r = await fetch(path, { ...options, headers });
    const text = await r.text(); let body = null; try { body = JSON.parse(text); } catch { body = text.slice(0,120); }
    return { status: r.status, body };
  }, { path, options });
}
const cands = await api("/api/v1/maintenance/prune-candidates");
console.log("candidates:", cands.status, cands.body.items.length, cands.body.items[0]?.id);
const prune = await api("/api/v1/maintenance/prune", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ids: [cands.body.items[0].id] }) });
console.log("prune:", prune.status, prune.body);
const gone = await api("/api/v1/bookmarks/" + cands.body.items[0].id);
console.log("after prune:", gone.status);
const undo = await api("/api/v1/undo", { method: "POST" });
console.log("undo:", undo.status, undo.body);
const back = await api("/api/v1/bookmarks/" + cands.body.items[0].id);
console.log("after undo:", back.status, back.body?.title);
await browser.close();
