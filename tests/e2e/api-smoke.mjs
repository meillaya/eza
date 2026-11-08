import { chromium } from "@playwright/test";

const BASE = process.env.EZA_BASE || "http://localhost:8084";
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();
const page = await context.newPage();
const errors = [];
page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
page.on("pageerror", (e) => errors.push(String(e)));

const cdp = await context.newCDPSession(page);
await cdp.send("WebAuthn.enable", { enableUI: false });
const { authenticatorId } = await cdp.send("WebAuthn.addVirtualAuthenticator", {
  options: { protocol: "ctap2", transport: "internal", hasResidentKey: true, hasUserVerification: true, isUserVerified: true, automaticPresenceSimulation: true },
});

await page.goto(BASE + "/setup", { waitUntil: "networkidle" });
await page.fill("#username", process.env.EZA_TEST_USER || "e2e");
await page.fill("#password", process.env.EZA_TEST_PASSWORD || "e2e-password-123");
await page.fill("#confirm-password", process.env.EZA_TEST_PASSWORD || "e2e-password-123");
await page.click("#password-setup");
await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });
console.log("setup: ok");

async function api(path, options = {}) {
  return page.evaluate(async ({ path, options }) => {
    const csrf = document.cookie.split("; ").find((c) => c.startsWith("eza_csrf="))?.split("=")[1] || "";
    const headers = { ...(options.headers || {}) };
    if (options.method && options.method !== "GET") headers["X-CSRF-Token"] = csrf;
    const r = await fetch(path, { ...options, headers });
    const text = await r.text();
    let body = null;
    try { body = JSON.parse(text); } catch { body = text.slice(0, 160); }
    return { status: r.status, body, contentType: r.headers.get("content-type") };
  }, { path, options });
}

const seeded = await api("/api/v1/bookmarks", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ url: "https://example.com/api-smoke", title: "API smoke", tags: ["smoke"] }),
});
console.log("seed", seeded.status, seeded.body?.id);

const boot = await api("/api/v1/boot");
console.log("boot", boot.status, "total", boot.body?.initial?.total, "first", boot.body?.initial?.items?.[0]?.id);
const firstId = boot.body.initial.items[0].id;
const search = await api("/api/v1/bookmarks?q=rust&limit=2");
console.log("search", search.status, search.body?.total, search.body?.items?.length);
const detail = await api("/api/v1/bookmarks/" + firstId);
console.log("detail", detail.status, detail.body?.id, "tags", detail.body?.tags?.length, "domain", detail.body?.domain);
const patch = await api("/api/v1/bookmarks/" + firstId, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ is_read: true }) });
console.log("patch", patch.status, patch.body);
const backlinks = await api("/api/v1/bookmarks/" + firstId + "/backlinks");
console.log("backlinks", backlinks.status, Object.keys(backlinks.body || {}));
const auto = await api("/api/v1/autocomplete?q=rust");
console.log("autocomplete", auto.status, auto.body?.items?.length);
const graph = await api("/api/v1/graph?seed=" + firstId + "&depth=1");
console.log("graph", graph.status, graph.body?.nodes?.length, graph.body?.edges?.length);
const savedCreate = await api("/api/v1/saved-searches", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: "Rust", q: "rust", tags: [] }) });
console.log("saved create", savedCreate.status, savedCreate.body);
const savedList = await api("/api/v1/saved-searches");
console.log("saved list", savedList.status, savedList.body?.saved_searches?.length);
const dedup = await api("/api/v1/dedup/candidates?url_limit=5&title_limit=5");
console.log("dedup", dedup.status, dedup.body?.counts);
const mergeAllRefused = await api("/api/v1/dedup/merge-all", { method: "POST", body: JSON.stringify({}) });
console.log("dedup merge-all refused", mergeAllRefused.status, mergeAllRefused.body?.error?.code);
const mergeAll = await api("/api/v1/dedup/merge-all", { method: "POST", body: JSON.stringify({ confirm: true }) });
console.log("dedup merge-all", mergeAll.status, mergeAll.body);
const tags = await api("/api/v1/tags/consolidation-candidates");
console.log("tags cleanup", tags.status, tags.body?.groups?.length);
const prune = await api("/api/v1/maintenance/prune-candidates");
console.log("prune candidates", prune.status, prune.body?.items?.length);
const account = await api("/api/v1/account");
console.log("account", account.status, Object.keys(account.body || {}), account.body?.recovery_codes_remaining);
const exported = await api("/api/v1/export");
console.log("export", exported.status, exported.contentType, typeof exported.body === "string" ? exported.body.slice(0, 40) : "json");

const importResult = await page.evaluate(async () => {
  const csrf = document.cookie.split("; ").find((c) => c.startsWith("eza_csrf="))?.split("=")[1] || "";
  const html = '<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n<DT><A HREF="https://example.com/eza-smoke" ADD_DATE="1700000000">Smoke</A>\n</DL><p>';
  const fd = new FormData();
  fd.append("file", new Blob([html], { type: "text/html" }), "smoke.html");
  const r = await fetch("/api/v1/import", { method: "POST", headers: { "X-CSRF-Token": csrf }, body: fd });
  return { status: r.status, body: await r.json() };
});
console.log("import", importResult.status, importResult.body?.inserted, importResult.body?.unique_urls);

console.log("console errors:", errors.filter((e) => !e.includes("401")).slice(0, 6));
await browser.close();
