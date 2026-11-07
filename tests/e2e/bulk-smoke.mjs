import { chromium } from "@playwright/test";
const BASE = process.env.EZA_BASE || "http://localhost:8108";
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();
const page = await context.newPage();
const cdp = await context.newCDPSession(page);
await cdp.send("WebAuthn.enable", { enableUI: false });
await cdp.send("WebAuthn.addVirtualAuthenticator", { options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true } });
await page.goto(BASE + "/setup", { waitUntil: "networkidle" });
await page.click("#passkey-setup");
await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });
async function cookieApi(path, options = {}) {
  return page.evaluate(async ({ path, options }) => {
    const csrf = document.cookie.split("; ").find((c) => c.startsWith("eza_csrf="))?.split("=")[1] || "";
    const headers = { ...(options.headers || {}) };
    if (options.method && options.method !== "GET") headers["X-CSRF-Token"] = csrf;
    const r = await fetch(path, { ...options, headers });
    const text = await r.text(); let body = null; try { body = JSON.parse(text); } catch { body = text.slice(0,160); }
    return { status: r.status, body };
  }, { path, options });
}
const created = await cookieApi("/api/v1/tokens", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: "bulk", scopes: ["read", "write"] }) });
const token = created.body.token;
async function tokenApi(path, options = {}) {
  return page.evaluate(async ({ path, options, token }) => {
    const headers = { ...(options.headers || {}), Authorization: "Bearer " + token };
    const r = await fetch(path, { ...options, headers });
    const text = await r.text(); let body = null; try { body = JSON.parse(text); } catch { body = text.slice(0,160); }
    return { status: r.status, body };
  }, { path, options, token });
}
const a = await tokenApi("/api/v1/bookmarks", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: "https://example.com/bulk-a", title: "Bulk A", tags: ["old"] }) });
const b = await tokenApi("/api/v1/bookmarks", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: "https://example.com/bulk-b", title: "Bulk B" }) });
console.log("created", created.status, a.status, b.status);
const ids = [a.body.id, b.body.id];
const add = await tokenApi("/api/v1/bookmarks/bulk", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: "add_tags", ids, tags: ["bulk-tag"] }) });
console.log("bulk add", add.status, add.body);
const afterAdd = await tokenApi("/api/v1/bookmarks/" + ids[1]);
console.log("tags after add", afterAdd.body.tags);
const undone = await tokenApi("/api/v1/undo", { method: "POST" });
console.log("undo add", undone.status, undone.body);
const afterUndo = await tokenApi("/api/v1/bookmarks/" + ids[1]);
console.log("tags after undo", afterUndo.body.tags);
const del = await tokenApi("/api/v1/bookmarks/bulk", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ action: "delete", ids, confirm: true }) });
console.log("bulk delete", del.status, del.body);
const missing = await tokenApi("/api/v1/bookmarks/" + ids[0]);
console.log("after delete", missing.status);
const restore = await tokenApi("/api/v1/undo", { method: "POST" });
console.log("undo delete", restore.status, restore.body);
const back = await tokenApi("/api/v1/bookmarks/" + ids[0]);
console.log("after restore", back.status, back.body?.title);
await browser.close();
