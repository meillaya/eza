import { chromium } from "@playwright/test";
const BASE = process.env.EZA_BASE || "http://localhost:8109";
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
    const r = await fetch(path, { ...options, headers });
    const text = await r.text(); let body = null; try { body = JSON.parse(text); } catch { body = text.slice(0,300); }
    return { status: r.status, body, headers: Object.fromEntries(r.headers.entries()) };
  }, { path, options });
}
const saved = await api("/api/v1/bookmarks", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: "https://example.com/share-test", title: "Share Test", tags: ["share"] }) });
const id = saved.body.id;
const created = await api("/api/v1/bookmarks/" + id + "/highlights", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ quote: "Share Test", prefix: "", suffix: "", start_offset: 0, end_offset: 10, note: "first", color: "yellow" }) });
console.log("highlight create", created.status, created.body);
const list = await api("/api/v1/bookmarks/" + id + "/highlights");
console.log("highlight list", list.status, list.body.highlights?.length);
const share = await api("/api/v1/share-links", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ scope: "bookmark", target_id: id, include_note: true, expires_in_days: 7 }) });
console.log("share", share.status, share.body);
const token = share.body.url.split("/s/")[1];
const publicPage = await page.evaluate(async (token) => { const r = await fetch("/s/" + token); return { status: r.status, text: (await r.text()).slice(0, 600), headers: Object.fromEntries(r.headers.entries()) }; }, token);
console.log("public", publicPage.status, publicPage.headers["x-robots-tag"], publicPage.text.includes("Share Test"));
const savedSearch = await api("/api/v1/saved-searches", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: "Shared search", q: "share", tags: [] }) });
console.log("saved search", savedSearch.status, savedSearch.body);
const feedShare = await api("/api/v1/share-links", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ scope: "saved_search", target_id: savedSearch.body.id, expires_in_days: 7 }) });
const feedToken = feedShare.body.url.split("/s/")[1];
const feed = await page.evaluate(async (token) => { const r = await fetch("/s/" + token + ".xml"); return { status: r.status, type: r.headers.get("content-type"), text: (await r.text()).slice(0, 400) }; }, feedToken);
console.log("feed", feed.status, feed.type, feed.text.startsWith("<?xml"));
await browser.close();
