// Sign-out smoke test.
//
// The sign-out control is visible on every screen (running head, mobile bar,
// account page) and through the command palette. A dirty record asks for
// confirmation first; a cancel keeps the session. Confirming posts
// /api/auth/logout, clears the cookies, lands on /login, and "/" afterwards
// redirects there again.
//
// Run from the repo root in the dev shell, against a fresh scratch server:
//   EZA_BASE=http://localhost:8100 node tests/e2e/logout-smoke.mjs
import { BASE, SEL, launchBrowser, launchPage, enterLibrary, newChecker } from "./lib/dom.mjs";

const browser = await launchBrowser();
const { page, context, errors } = await launchPage(browser, { viewport: { width: 1360, height: 900 } });
const { check, report } = newChecker();

const sleep = (ms) => page.waitForTimeout(ms);

async function cookieNames() {
  const cookies = await context.cookies(BASE);
  return cookies.map((cookie) => cookie.name);
}

async function signOutFor(expectedStatus = 204) {
  const logout = page.waitForResponse(
    (response) => response.url().endsWith("/api/auth/logout") && response.request().method() === "POST",
    { timeout: 20000 }
  );
  await page.click('[data-testid="section-sign-out"]');
  const response = await logout;
  return response.status();
}

async function waitForLogin() {
  await page.waitForURL("**/login*", { timeout: 20000 });
}

try {
  await enterLibrary(page);
  await page.waitForSelector(SEL.appShell, { timeout: 30000 });
  await sleep(500);

  // ------------------------------------------------ clean sign-out --------
  check(
    "sign-out is visible in the running head",
    (await page.locator('[data-testid="section-sign-out"]').isVisible()),
    "section-sign-out"
  );
  check(
    "sign-out is present in the mobile bar",
    (await page.locator('[data-testid="m-nav-sign-out"]').count()) === 1,
    "m-nav-sign-out"
  );

  const cleanStatus = await signOutFor();
  check("signing out posts /api/auth/logout with 204", cleanStatus === 204, "status " + cleanStatus);
  await waitForLogin();
  await sleep(400);
  const afterClean = await cookieNames();
  check(
    "both auth cookies are gone after sign-out",
    !afterClean.includes("eza_session") && !afterClean.includes("eza_csrf"),
    afterClean.join(",") || "(none)"
  );

  await page.goto(BASE + "/", { waitUntil: "domcontentloaded" });
  await sleep(400);
  check("a signed-out visit to / redirects to /login", page.url().includes("/login"), page.url());

  // ------------------------------------------------ dirty sign-out --------
  await enterLibrary(page);
  await page.waitForSelector(SEL.row, { timeout: 30000 });
  await sleep(500);
  const recordId = await page.locator(SEL.row).first().getAttribute("data-bookmark-id");
  await page.goto(BASE + "/bookmark/" + recordId, { waitUntil: "domcontentloaded" });
  await page.waitForSelector(SEL.record, { timeout: 30000 });
  await sleep(500);

  await page.click("#note-editor");
  await page.keyboard.type(" unsaved note before signing out");
  await sleep(200);

  let logoutRequests = 0;
  const countLogout = (request) => {
    if (request.method() === "POST" && request.url().endsWith("/api/auth/logout")) logoutRequests += 1;
  };
  page.on("request", countLogout);

  await page.click('[data-testid="section-sign-out"]');
  await page.waitForSelector('[data-testid="dialog-logout"]', { timeout: 15000 });
  const dialogText = (await page.locator('[data-testid="dialog-logout"]').innerText()).toLowerCase();
  check("signing out with an unsaved note asks first", true, "dialog-logout");
  check(
    "the confirmation explains the unsaved note",
    dialogText.includes("not been saved"),
    dialogText.slice(0, 120)
  );
  check("no logout request is sent before confirmation", logoutRequests === 0, String(logoutRequests));
  check("the record page is still open", page.url().includes("/bookmark/"), page.url());

  await page.click('[data-testid="dialog-cancel"]');
  await sleep(400);
  check(
    "cancel closes the confirmation",
    (await page.locator('[data-testid="dialog-logout"]').count()) === 0,
    "dialog-logout removed"
  );
  const afterCancel = await cookieNames();
  check(
    "cancel keeps the session signed in",
    afterCancel.includes("eza_session"),
    afterCancel.join(",") || "(none)"
  );
  check("cancel leaves the record open", page.url().includes("/bookmark/"), page.url());

  // ------------------------------------------------ confirm the dirty -----
  const dirtyLogout = page.waitForResponse(
    (response) => response.url().endsWith("/api/auth/logout") && response.request().method() === "POST",
    { timeout: 20000 }
  );
  await page.click('[data-testid="section-sign-out"]');
  await page.waitForSelector('[data-testid="dialog-logout"]', { timeout: 15000 });
  await page.click('[data-testid="dialog-confirm"]');
  const dirtyResponse = await dirtyLogout;
  check("confirming the dirty sign-out posts the logout", dirtyResponse.status() === 204, "status " + dirtyResponse.status());
  await waitForLogin();
  await sleep(400);
  const afterDirty = await cookieNames();
  check(
    "the dirty sign-out clears the auth cookies",
    !afterDirty.includes("eza_session") && !afterDirty.includes("eza_csrf"),
    afterDirty.join(",") || "(none)"
  );
  page.off("request", countLogout);

  // ------------------------------------------------ palette sign-out -------
  await enterLibrary(page);
  await page.waitForSelector(SEL.appShell, { timeout: 30000 });
  await sleep(500);
  await page.keyboard.press("Control+k");
  await page.waitForSelector(SEL.palette, { timeout: 15000 });
  await page.fill(SEL.paletteInput, "sign out");
  await sleep(300);
  const paletteText = (await page.locator(SEL.palette).innerText()).toLowerCase();
  check("the palette offers Sign out", paletteText.includes("sign out"), paletteText.slice(0, 120));

  const paletteLogout = page.waitForResponse(
    (response) => response.url().endsWith("/api/auth/logout") && response.request().method() === "POST",
    { timeout: 20000 }
  );
  await page.keyboard.press("Enter");
  const paletteResponse = await paletteLogout;
  check("the palette signs out", paletteResponse.status() === 204, "status " + paletteResponse.status());
  await waitForLogin();
  await sleep(300);
  const afterPalette = await cookieNames();
  check(
    "the palette sign-out clears the session",
    !afterPalette.includes("eza_session"),
    afterPalette.join(",") || "(none)"
  );
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report(errors);
