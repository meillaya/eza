// Bulk-action smoke through an API token: create a read/write token, add and
// delete bookmarks in bulk, and prove each bulk write has a working undo.
// Part of the default e2e suite; every step asserts.
import { launchBrowser, launchPage, newChecker } from "./lib/dom.mjs";

const BASE = process.env.EZA_BASE || "http://localhost:8108";
const USER = process.env.EZA_TEST_USER || "e2e";
const PASSWORD = process.env.EZA_TEST_PASSWORD || "e2e-password-123";

const { check, report } = newChecker();
const browser = await launchBrowser();
const { context, page, errors } = await launchPage(browser);

try {
  await page.goto(BASE + "/setup", { waitUntil: "networkidle" });
  await page.fill("#username", USER);
  await page.fill("#password", PASSWORD);
  await page.fill("#confirm-password", PASSWORD);
  await page.click("#password-setup");
  await page.waitForSelector("#recovery:not([hidden])", { timeout: 30000 });

  const created = await page.evaluate(async () => {
    const csrf = document.cookie.split("; ").find((c) => c.startsWith("eza_csrf="))?.split("=")[1] || "";
    const r = await fetch("/api/v1/tokens", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf },
      body: JSON.stringify({ name: "bulk", scopes: ["read", "write"] }),
    });
    return { status: r.status, body: await r.json() };
  });
  check("create a read/write token", created.status === 201 && typeof created.body?.token === "string", String(created.status));
  const token = created.body?.token || "";

  const tokenApi = (path, options = {}) =>
    page.evaluate(
      async ({ path, options, token }) => {
        const headers = { ...(options.headers || {}), Authorization: "Bearer " + token };
        const r = await fetch(path, { ...options, headers });
        const text = await r.text();
        let body = null;
        try {
          body = JSON.parse(text);
        } catch {
          body = text.slice(0, 160);
        }
        return { status: r.status, body };
      },
      { path, options, token },
    );

  const a = await tokenApi("/api/v1/bookmarks", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ url: "https://example.com/bulk-a", title: "Bulk A", tags: ["old"] }),
  });
  const b = await tokenApi("/api/v1/bookmarks", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ url: "https://example.com/bulk-b", title: "Bulk B" }),
  });
  check("token can create bookmarks", a.status === 201 && b.status === 201, `${a.status}/${b.status}`);
  const ids = [a.body?.id, b.body?.id];

  const add = await tokenApi("/api/v1/bookmarks/bulk", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "add_tags", ids, tags: ["bulk-tag"] }),
  });
  check("bulk add_tags answers 200 and updates both rows", add.status === 200 && add.body?.updated === 2, `${add.status}/${add.body?.updated}`);
  const afterAdd = await tokenApi("/api/v1/bookmarks/" + ids[1]);
  check("the tag is on the second record", Array.isArray(afterAdd.body?.tags) && afterAdd.body.tags.includes("bulk-tag"));

  const undone = await tokenApi("/api/v1/undo", { method: "POST" });
  check("undo of the bulk tag add answers 200", undone.status === 200, String(undone.status));
  const afterUndo = await tokenApi("/api/v1/bookmarks/" + ids[1]);
  check("undo removes the bulk tag", Array.isArray(afterUndo.body?.tags) && !afterUndo.body.tags.includes("bulk-tag"));

  const del = await tokenApi("/api/v1/bookmarks/bulk", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "delete", ids, confirm: true }),
  });
  check("bulk delete answers 200 and deletes both rows", del.status === 200 && del.body?.updated === 2, `${del.status}/${del.body?.updated}`);
  const missing = await tokenApi("/api/v1/bookmarks/" + ids[0]);
  check("a bulk-deleted record is gone", missing.status === 404, String(missing.status));

  const restore = await tokenApi("/api/v1/undo", { method: "POST" });
  check("undo of the bulk delete answers 200", restore.status === 200, String(restore.status));
  const back = await tokenApi("/api/v1/bookmarks/" + ids[0]);
  check("undo restores the deleted record", back.status === 200 && back.body?.title === "Bulk A", `${back.status}/${back.body?.title}`);

  const noConfirm = await tokenApi("/api/v1/bookmarks/bulk", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "delete", ids }),
  });
  check("bulk delete without confirm is refused", noConfirm.status === 400, String(noConfirm.status));

  const jsErrors = errors.filter((error) => !/Failed to load resource/.test(error));
  check("no page errors", jsErrors.length === 0, jsErrors.slice(0, 3).join(" | "));
} finally {
  await context.close();
  await browser.close();
  report(errors);
}
