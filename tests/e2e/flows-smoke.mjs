import { chromium } from "@playwright/test";

const BASE = process.env.EZA_BASE || "http://localhost:8088";
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();
const page = await context.newPage();
const errors = [];
page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
page.on("pageerror", (e) => errors.push(String(e)));

const cdp = await context.newCDPSession(page);
await cdp.send("WebAuthn.enable", { enableUI: false });
await cdp.send("WebAuthn.addVirtualAuthenticator", {
  options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true },
});

await page.goto(BASE + "/setup", { waitUntil: "networkidle" });
await page.click("#passkey-setup");
await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });

async function api(path, options = {}) {
  return page.evaluate(async ({ path, options }) => {
    const csrf = document.cookie.split("; ").find((c) => c.startsWith("eza_csrf="))?.split("=")[1] || "";
    const headers = { ...(options.headers || {}) };
    if (options.method && options.method !== "GET") headers["X-CSRF-Token"] = csrf;
    const r = await fetch(path, { ...options, headers });
    const text = await r.text();
    let body = null;
    try { body = JSON.parse(text); } catch { body = text.slice(0, 200); }
    return { status: r.status, body };
  }, { path, options });
}

const addA = await api("/api/v1/bookmarks", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: "https://example.com/a", title: "Alpha Reference", tags: ["smoke-a"] }) });
const addB = await api("/api/v1/bookmarks", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: "https://example.com/b", title: "Beta Reference", tags: ["smoke-b"] }) });
console.log("add:", addA.status, addA.body, addB.status, addB.body);
const a = addA.body.id, b = addB.body.id;

const patch = await api("/api/v1/bookmarks/" + b, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ note_body: "See [[Alpha Reference]] for context.", title: "Beta Reference" }) });
console.log("patch:", patch.status, patch.body);
const detailB = await api("/api/v1/bookmarks/" + b);
const detailA = await api("/api/v1/bookmarks/" + a);
console.log("detail B links:", detailB.body.links);
const backB = await api("/api/v1/bookmarks/" + b + "/backlinks");
const backA = await api("/api/v1/bookmarks/" + a + "/backlinks");
console.log("backlinks B:", JSON.stringify(backB.body).slice(0, 300));
console.log("backlinks A:", JSON.stringify(backA.body).slice(0, 300));

const tagPatch = await api("/api/v1/bookmarks/" + a, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ tags: ["smoke-a", "smoke-z"] }) });
const detailA2 = await api("/api/v1/bookmarks/" + a);
console.log("tags:", tagPatch.status, detailA2.body.tags);

const search = await api("/api/v1/bookmarks?q=Beta&limit=5");
console.log("search beta:", search.status, search.body.total);
const suggest = await api("/api/v1/tags/smoke-a/suggestions");
console.log("ai suggestions (no key expected 400):", suggest.status, JSON.stringify(suggest.body).slice(0, 160));

const del = await api("/api/v1/bookmarks/" + b, { method: "DELETE" });
console.log("delete:", del.status);
console.log("console errors:", errors.slice(0, 6));
await browser.close();
