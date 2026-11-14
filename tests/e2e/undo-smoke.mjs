import { chromium } from "@playwright/test";
const BASE = process.env.EZA_BASE || "http://localhost:8095";
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
    const text = await r.text();
    let body = null; try { body = JSON.parse(text); } catch { body = text.slice(0,120); }
    return { status: r.status, body };
  }, { path, options });
}
const a = await api("/api/v1/bookmarks", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: "https://example.com/dup", title: "Dup One", tags: ["undo-test"] }) });
const b = await api("/api/v1/bookmarks", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: "https://example.com/dup/", title: "Dup Two", tags: ["undo-test"] }) });
console.log("created", a.status, a.body, b.status, b.body);
const groups = await api("/api/v1/dedup/candidates");
const group = (groups.body.groups || []).find((g) => (g.items || []).some((i) => i.id === b.body.id));
console.log("candidate group found:", !!group, group && group.key);
if (group) {
  const merge = await api("/api/v1/dedup/merge", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ keep_id: group.items[0].id, merge_ids: group.items.slice(1).map((i) => i.id) }) });
  console.log("merge:", merge.status, merge.body);
  const after = await api("/api/v1/bookmarks/" + b.body.id);
  console.log("merged row status:", after.status);
  const undo = await api("/api/v1/undo", { method: "POST" });
  console.log("undo:", undo.status, undo.body);
  const restored = await api("/api/v1/bookmarks/" + b.body.id);
  console.log("restored row status:", restored.status, restored.body && restored.body.title);
}
const sug = await api("/api/v1/ai/suggestions", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ tag: "imported" }),
});
console.log("suggestion job:", sug.status, JSON.stringify(sug.body).slice(0, 150));
if (sug.status === 202) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const job = await api("/api/v1/jobs/" + sug.body.job_id);
    if (job.status === 200 && ["done", "failed", "cancelled"].includes(job.body?.state)) {
      console.log("suggestion job state:", job.status, job.body?.state, JSON.stringify(job.body?.result).slice(0, 120));
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
}
await browser.close();
