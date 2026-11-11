// Highlights and share links: create a highlight, share the record, read the
// public page, then share a saved search and read its Atom feed. Part of the
// default e2e suite; every step asserts.
import { launchBrowser, launchPage, makeApi, newChecker } from "./lib/dom.mjs";

const BASE = process.env.EZA_BASE || "http://localhost:8109";
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

  const api = makeApi(page);

  const saved = await api("/api/v1/bookmarks", {
    method: "POST",
    body: JSON.stringify({ url: "https://example.com/share-test", title: "Share Test", tags: ["share"] }),
  });
  check("create the record to share", saved.status === 201 && Number.isInteger(saved.body?.id), String(saved.status));
  const id = saved.body?.id;

  const created = await api("/api/v1/bookmarks/" + id + "/highlights", {
    method: "POST",
    body: JSON.stringify({ quote: "Share Test", prefix: "", suffix: "", start_offset: 0, end_offset: 10, note: "first", color: "yellow" }),
  });
  check("create a highlight", created.status === 201, String(created.status));
  const list = await api("/api/v1/bookmarks/" + id + "/highlights");
  check("list the highlights", list.status === 200 && Array.isArray(list.body?.highlights) && list.body.highlights.length === 1);

  const share = await api("/api/v1/share-links", {
    method: "POST",
    body: JSON.stringify({ scope: "bookmark", target_id: id, include_note: true, expires_in_days: 7 }),
  });
  check("create a bookmark share link", share.status === 201 && typeof share.body?.url === "string", String(share.status));
  const token = String(share.body?.url || "").split("/s/")[1];

  const publicPage = await page.evaluate(async (token) => {
    const r = await fetch("/s/" + token);
    return { status: r.status, text: (await r.text()).slice(0, 2000), headers: Object.fromEntries(r.headers.entries()) };
  }, token);
  check("the public share page answers 200", publicPage.status === 200, String(publicPage.status));
  check("the share page carries the record title", publicPage.text.includes("Share Test"));
  check("the share page is noindex", publicPage.headers["x-robots-tag"] === "noindex", String(publicPage.headers["x-robots-tag"]));

  const savedSearch = await api("/api/v1/saved-searches", {
    method: "POST",
    body: JSON.stringify({ name: "Shared search", q: "share", tags: [] }),
  });
  check("create a saved search", savedSearch.status === 201 && Number.isInteger(savedSearch.body?.id), String(savedSearch.status));

  const feedShare = await api("/api/v1/share-links", {
    method: "POST",
    body: JSON.stringify({ scope: "saved_search", target_id: savedSearch.body?.id, expires_in_days: 7 }),
  });
  check("create a saved-search share link", feedShare.status === 201 && typeof feedShare.body?.url === "string", String(feedShare.status));
  const feedToken = String(feedShare.body?.url || "").split("/s/")[1];

  const feed = await page.evaluate(async (token) => {
    const r = await fetch("/s/" + token + ".xml");
    return { status: r.status, type: r.headers.get("content-type"), text: (await r.text()).slice(0, 400) };
  }, feedToken);
  check("the saved-search feed answers 200 with Atom", feed.status === 200 && String(feed.type || "").includes("atom"), `${feed.status}/${feed.type}`);
  check("the feed is an XML document", feed.text.startsWith("<?xml"));

  const revoke = await api("/api/v1/share-links/" + share.body?.id, { method: "DELETE" });
  check("revoking the share link answers 200/204", revoke.status === 200 || revoke.status === 204, String(revoke.status));
  const gone = await page.evaluate(async (token) => (await fetch("/s/" + token)).status, token);
  check("a revoked share link answers 410", gone === 410, String(gone));

  const jsErrors = errors.filter((error) => !/Failed to load resource/.test(error));
  check("no page errors", jsErrors.length === 0, jsErrors.slice(0, 3).join(" | "));
} finally {
  await context.close();
  await browser.close();
  report(errors);
}
