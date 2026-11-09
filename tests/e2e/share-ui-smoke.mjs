// Share-link UI smoke test: bookmark share dialog (include note + expiry),
// created URL + copy, public read-only page, existing links, revoke from the
// account section, revoked link 404, and the AI status banner.
//
// Run from the repo root in the dev shell, against a scratch server:
//   EZA_BASE=http://localhost:8100 node tests/e2e/share-ui-smoke.mjs
import { BASE, SEL, launchBrowser, launchPage, enterLibrary, makeApi, newChecker } from "./lib/dom.mjs";

const browser = await launchBrowser();
const { context, page, errors } = await launchPage(browser, { viewport: { width: 1440, height: 1000 } });
const { check, report } = newChecker();
const api = makeApi(page);

async function openRecord(id) {
  await page.goto(BASE + "/bookmark/" + id, { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.appShell, { timeout: 30000 });
  await page.waitForSelector(SEL.record, { timeout: 30000 });
  await page.waitForTimeout(500);
}

async function openShareDialog() {
  await page.getByRole("button", { name: /^share$/i }).first().click();
  await page.waitForSelector(SEL.shareDialog, { timeout: 20000 });
  await page.waitForTimeout(300);
}

try {
  await enterLibrary(page);

  const listing = await api("/api/v1/bookmarks?limit=1&offset=0");
  const bookmark = (listing.body?.items || [])[0];
  check("bookmark available for sharing", Boolean(bookmark), JSON.stringify(bookmark || {}).slice(0, 120));
  if (!bookmark) throw new Error("no bookmarks on the scratch server");
  await openRecord(bookmark.id);

  // The snapshot action is only exposed for a local file snapshot.
  const detail = (await api("/api/v1/bookmarks/" + bookmark.id)).body || {};
  const snapshotButton = page.locator(SEL.snapshotOpen);
  const snapshotCount = await snapshotButton.count();
  check(
    "snapshot button matches snapshot availability",
    (detail.snapshot_kind === "file") === (snapshotCount > 0),
    "kind=" + JSON.stringify(detail.snapshot_kind) + " buttons=" + snapshotCount
  );
  if (snapshotCount > 0) {
    await snapshotButton.first().click();
    await page.waitForSelector(SEL.snapshotFrame, { timeout: 10000 });
    const frame = page.locator(SEL.snapshotFrame);
    const frameSrc = await frame.getAttribute("src");
    const frameSandbox = await frame.getAttribute("sandbox");
    const snapshotResponse = await api("/api/v1/bookmarks/" + bookmark.id + "/snapshot");
    check(
      "snapshot iframe is the sandboxed snapshot route",
      frameSrc === "/api/v1/bookmarks/" + bookmark.id + "/snapshot" && frameSandbox !== null,
      String(frameSrc) + " sandbox=" + JSON.stringify(frameSandbox)
    );
    check("snapshot endpoint serves html", snapshotResponse.status === 200, "status " + snapshotResponse.status);
    await page.locator(SEL.snapshotClose).click();
    await page.waitForTimeout(300);
  }

  await openShareDialog();
  check("share dialog opens", (await page.locator(SEL.shareDialog).count()) === 1);

  // Configure expiry and note, then create the link.
  await page.locator(SEL.shareIncludeNote).check();
  await page.selectOption(SEL.shareExpiry, "7");
  await page.locator(SEL.shareCreate).click();
  await page.waitForSelector(SEL.shareReveal, { timeout: 20000 });
  const shareUrl = (await page.locator(SEL.shareUrl).innerText()).trim();
  check("share url shown", shareUrl.startsWith("http") && shareUrl.includes("/s/"), shareUrl.slice(0, 60) + "...");
  const expiryDays = await page.evaluate((selector) => {
    const element = document.querySelector(selector);
    return element ? element.value : null;
  }, SEL.shareExpiry);
  check("expiry selection captured", expiryDays === "7", String(expiryDays));

  await context.grantPermissions(["clipboard-read", "clipboard-write"], { origin: BASE });
  await page.locator(SEL.shareCopy).click();
  await page.waitForTimeout(500);
  const clipboard = await page.evaluate(() => navigator.clipboard.readText().catch(() => ""));
  check("copy share link", clipboard === shareUrl, clipboard.slice(0, 40) + "...");

  // Server state.
  const sharesResponse = await api("/api/v1/share-links");
  const shares = sharesResponse.body?.shares || [];
  const created = shares.find(
    (entry) => entry.scope === "bookmark" && entry.target_id === bookmark.id && !entry.revoked_at
  );
  const now = Math.floor(Date.now() / 1000);
  check("share link listed via api", Boolean(created), JSON.stringify(shares).slice(0, 160));
  check("share target and scope", created?.target_id === bookmark.id && created?.scope === "bookmark");
  check("include-note stored", created?.include_note === true, String(created?.include_note));
  check(
    "expiry is about 7 days",
    Boolean(created) && created.expires_at > now + 6 * 86400 && created.expires_at < now + 8 * 86400,
    created ? "expires in " + Math.round((created.expires_at - now) / 86400) + "d" : "missing"
  );

  // Existing links are listed in the dialog after a reload.
  await openRecord(bookmark.id);
  await openShareDialog();
  await page.waitForSelector(SEL.shareRow, { timeout: 20000 });
  check("existing link listed in dialog", (await page.locator(SEL.shareRow).count()) >= 1);
  await page.keyboard.press("Escape");

  // Public page works without a session.
  const publicContext = await browser.newContext();
  const publicPage = await publicContext.newPage();
  const publicResponse = await publicPage.goto(shareUrl, { waitUntil: "domcontentloaded" });
  await publicPage.waitForSelector(SEL.sharePage, { timeout: 20000 }).catch(() => {});
  const publicTitle = await publicPage.locator("h1").first().innerText().catch(() => "");
  check("public share page 200", publicResponse?.status() === 200, "status " + (publicResponse ? publicResponse.status() : "?"));
  check(
    "public page shows bookmark title",
    publicTitle.trim().length > 0 &&
      (publicTitle.includes(bookmark.title) || bookmark.title.includes(publicTitle.trim())),
    publicTitle.slice(0, 60)
  );
  await publicContext.close();

  // Account section + revoke.
  await page.goto(BASE + "/account", { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.appShell, { timeout: 30000 });
  // The shell paints before the boot re-render settles; wait one beat so the
  // account tab click is not lost to the re-render.
  await page.waitForTimeout(500);
  await page.click(SEL.accountTab("shares"));
  await page.waitForSelector(SEL.accountPanel("shares"), { timeout: 20000 });
  const accountShareRow = page.locator(SEL.shareLinkRow, { hasText: String(bookmark.id) }).first();
  check("account lists the bookmark share", (await accountShareRow.count()) >= 1);
  if ((await accountShareRow.count()) > 0) {
    await accountShareRow.locator(SEL.shareLinkRevoke).click();
    await page.waitForSelector(SEL.toast, { timeout: 20000 }).catch(() => {});
  }
  let revoked = null;
  for (let attempt = 0; attempt < 12; attempt++) {
    await page.waitForTimeout(400);
    const afterRevoke = await api("/api/v1/share-links");
    revoked = (afterRevoke.body?.shares || []).find((entry) => entry.id === created?.id);
    if (revoked?.revoked_at) break;
  }
  check("share revoked on server", Boolean(revoked?.revoked_at), String(revoked?.revoked_at));

  // The revoked link is gone for the public.
  const revokedContext = await browser.newContext();
  const revokedPage = await revokedContext.newPage();
  const revokedResponse = await revokedPage.goto(shareUrl, { waitUntil: "domcontentloaded" });
  const unavailable = await revokedPage.locator(SEL.shareUnavailable).count();
  check(
    "revoked share page is gone",
    [404, 410].includes(revokedResponse?.status()),
    "status " + (revokedResponse ? revokedResponse.status() : "?")
  );
  check("revoked share page shows the unavailable page", unavailable > 0);
  await revokedContext.close();

  // AI tags route and the honest provider banner.
  await page.goto(BASE + "/", { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.appShell, { timeout: 30000 });
  const aiLink = page.locator(SEL.section("ai-tags"));
  if ((await aiLink.count()) > 0) {
    await aiLink.first().click();
  } else {
    await page.goto(BASE + "/tags/ai", { waitUntil: "domcontentloaded" });
  }
  await page.waitForSelector(SEL.aiBanner, { timeout: 20000 });
  await page
    .waitForFunction(
      (selector) => {
        const node = document.querySelector(selector);
        return Boolean(node && /(not configured|configured|none)/i.test(node.textContent || ""));
      },
      SEL.aiBanner,
      { timeout: 20000 }
    )
    .catch(() => {});
  const bannerText = (await page.locator(SEL.aiBanner).innerText()).replace(/\n+/g, " ");
  check(
    "ai status banner shows the provider state",
    /provider/i.test(bannerText) && /(not configured|configured|none)/i.test(bannerText),
    bannerText.slice(0, 100)
  );
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
