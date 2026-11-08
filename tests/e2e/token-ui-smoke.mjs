// API token UI smoke test: account section, empty state, create with scopes,
// one-time reveal + copy, bearer use, reload, revoke.
//
// Run from the repo root in the dev shell, against a scratch server:
//   EZA_BASE=http://localhost:8100 node tests/e2e/token-ui-smoke.mjs
import { BASE, SEL, launchBrowser, launchPage, enterLibrary, makeApi, newChecker } from "./lib/dom.mjs";

const browser = await launchBrowser();
const { context, page, errors } = await launchPage(browser, { viewport: { width: 1440, height: 1000 } });
const { check, report } = newChecker();
const api = makeApi(page);

async function openTokens() {
  await page.goto(BASE + "/account", { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.appShell, { timeout: 30000 });
  await page.click(SEL.accountTab("tokens"));
  await page.waitForSelector(SEL.accountPanel("tokens"), { timeout: 20000 });
  await page.waitForSelector(SEL.tokenName, { timeout: 20000 });
  await page.waitForTimeout(400);
}

try {
  await enterLibrary(page);
  await openTokens();

  check("API tokens panel present", (await page.locator(SEL.accountPanel("tokens")).count()) === 1);
  const emptyState = await page
    .locator(SEL.tokenEmpty)
    .or(page.getByText(/no (api )?tokens( yet)?/i))
    .count();
  check("empty state", emptyState > 0);

  // Create a token with the capture scope on top of the default read/write.
  await page.fill(SEL.tokenName, "E2E token");
  await page.locator(SEL.tokenScope("capture")).evaluate((element) => element.click());
  await page.locator(SEL.tokenCreate).click();
  await page.waitForSelector(SEL.tokenReveal, { timeout: 20000 });
  const rawToken = (await page.locator(SEL.tokenSecret).innerText()).trim();
  check("one-time reveal shown", rawToken.startsWith("eza_pat_"), rawToken.slice(0, 12) + "...");
  const revealCopy = (await page.locator(SEL.tokenReveal).innerText()).toLowerCase();
  check("one-time warning shown", /once|again/.test(revealCopy), revealCopy.replace(/\n+/g, " ").slice(0, 80));

  await context.grantPermissions(["clipboard-read", "clipboard-write"], { origin: BASE });
  await page.locator(SEL.tokenReveal).getByRole("button", { name: /copy/i }).first().click();
  await page.waitForTimeout(500);
  const clipboard = await page.evaluate(() => navigator.clipboard.readText().catch(() => ""));
  check("copy token writes clipboard", clipboard === rawToken, clipboard.slice(0, 12) + "...");

  // The token list carries the metadata through the API.
  const list = await api("/api/v1/tokens");
  const created = (list.body?.tokens || [])[0];
  check("token listed via api", Boolean(created), JSON.stringify(list.body || {}).slice(0, 120));
  check("token name stored", created?.name === "E2E token", String(created?.name));
  check(
    "token scopes stored",
    JSON.stringify(created?.scopes || []) === JSON.stringify(["read", "write", "capture"]),
    JSON.stringify(created?.scopes)
  );
  check("token is not revoked", created?.revoked_at === null || created?.revoked_at === undefined, String(created?.revoked_at));

  // The raw token works as a bearer for quick save (capture scope).
  const bearerSave = await page.evaluate(async (raw) => {
    const response = await fetch("/api/v1/quick-save", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + raw },
      body: JSON.stringify({ url: "https://example.com/token-smoke-" + Date.now(), title: "Token smoke" }),
    });
    return { status: response.status, body: await response.json().catch(() => null) };
  }, rawToken);
  check("bearer token quick-saves", [200, 201].includes(bearerSave.status), JSON.stringify(bearerSave));

  // Reload: the reveal is gone, the token row is listed, revoke works.
  await openTokens();
  check("reveal is one-time only", (await page.locator(SEL.tokenReveal).count()) === 0);
  const tokenRow = page.locator(SEL.tokenRow, { hasText: "E2E token" }).first();
  check("token row visible after reload", (await tokenRow.count()) > 0);

  await tokenRow.locator(SEL.tokenRevoke).click();
  await page.waitForSelector(SEL.toast, { timeout: 20000 }).catch(() => {});
  let revoked = null;
  for (let attempt = 0; attempt < 12; attempt++) {
    await page.waitForTimeout(400);
    const afterRevoke = await api("/api/v1/tokens");
    revoked = (afterRevoke.body?.tokens || []).find((token) => token.name === "E2E token");
    if (revoked?.revoked_at) break;
  }
  check("revoked_at set on server", Boolean(revoked?.revoked_at), String(revoked?.revoked_at));
  const rowText = await tokenRow.innerText().catch(() => "");
  check("revoked state shown in UI", /revoked/i.test(rowText), rowText.replace(/\n+/g, " ").slice(0, 100));

  // Revoked bearer is rejected.
  const revokedSave = await page.evaluate(async (raw) => {
    const response = await fetch("/api/v1/quick-save", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer " + raw },
      body: JSON.stringify({ url: "https://example.com/token-revoked-" + Date.now() }),
    });
    return { status: response.status };
  }, rawToken);
  check("revoked bearer rejected", revokedSave.status === 401, "status " + revokedSave.status);
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
