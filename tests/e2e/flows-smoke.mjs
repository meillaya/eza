// Cross-feature smoke flow: save two bookmarks, patch a note with a wikilink,
// check backlinks and tag edits, then search and delete. Every step asserts the
// contract; the script fails when an endpoint regresses.
import { launchBrowser, launchPage, makeApi, newChecker } from "./lib/dom.mjs";

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
  check("setup creates the first account", true);

  const api = makeApi(page);

  const addA = await api("/api/v1/bookmarks", {
    method: "POST",
    body: JSON.stringify({ url: "https://example.com/flow-alpha", title: "Alpha Reference", tags: ["smoke-a"] }),
  });
  const addB = await api("/api/v1/bookmarks", {
    method: "POST",
    body: JSON.stringify({ url: "https://example.com/flow-beta", title: "Beta Reference", tags: ["smoke-b"] }),
  });
  check("adding a bookmark answers 201", addA.status === 201 && addB.status === 201, `${addA.status}/${addB.status}`);
  check("add returns a numeric id", Number.isInteger(addA.body?.id) && Number.isInteger(addB.body?.id));
  const a = addA.body?.id;
  const b = addB.body?.id;

  const duplicate = await api("/api/v1/bookmarks", {
    method: "POST",
    body: JSON.stringify({ url: "https://example.com/flow-alpha", title: "Alpha again" }),
  });
  check("a duplicate URL is refused with 409", duplicate.status === 409, String(duplicate.status));

  const patch = await api("/api/v1/bookmarks/" + b, {
    method: "PATCH",
    body: JSON.stringify({ note_body: "See [[Alpha Reference]] for context.", title: "Beta Reference" }),
  });
  check("patching the note answers 200", patch.status === 200, String(patch.status));

  const detailB = await api("/api/v1/bookmarks/" + b);
  check("the patched bookmark carries the note", detailB.status === 200 && String(detailB.body?.note_body || "").includes("Alpha Reference"));
  const backA = await api("/api/v1/bookmarks/" + a + "/backlinks");
  check("the wikilink resolves to a backlink", backA.status === 200 && Array.isArray(backA.body?.linked) && backA.body.linked.length >= 1);

  const tagPatch = await api("/api/v1/bookmarks/" + a, {
    method: "PATCH",
    body: JSON.stringify({ tags: ["smoke-a", "smoke-z"] }),
  });
  const detailA = await api("/api/v1/bookmarks/" + a);
  check("tag patch answers 200 and stores both tags", tagPatch.status === 200 && Array.isArray(detailA.body?.tags) && detailA.body.tags.includes("smoke-z"));

  const search = await api("/api/v1/bookmarks?q=Beta&limit=5");
  check("search finds the saved record", search.status === 200 && search.body?.total >= 1, String(search.body?.total));

  const suggest = await api("/api/v1/tags/smoke-a/suggestions");
  check("AI suggestions answer 200/400 without a key", suggest.status === 200 || suggest.status === 400, String(suggest.status));

  const del = await api("/api/v1/bookmarks/" + b, { method: "DELETE" });
  const afterDelete = await api("/api/v1/bookmarks/" + b);
  check("delete answers 200/204", del.status === 200 || del.status === 204, String(del.status));
  check("the deleted record is gone", afterDelete.status === 404, String(afterDelete.status));

  const jsErrors = errors.filter((error) => !/Failed to load resource/.test(error));
  check("no page errors", jsErrors.length === 0, jsErrors.slice(0, 3).join(" | "));
} finally {
  await context.close();
  await browser.close();
  report(errors);
}
