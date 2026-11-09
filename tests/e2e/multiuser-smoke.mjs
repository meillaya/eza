// Multi-user smoke test: two accounts on one server.
//
// The harness claims one admin account (EZA_TEST_USER) with the mini fixture.
// This script uses its admin session to create a second member account through
// the admin API, signs a second browser context in as that member, and checks
// that the two libraries, views, webhooks, tokens and share links stay apart.
import {
  BASE,
  SEL,
  enterLibrary,
  enterLibraryAs,
  launchBrowser,
  launchPage,
  makeApi,
  newChecker,
} from "./lib/dom.mjs";

const ADMIN_USER = process.env.EZA_TEST_USER || "e2e";
const ADMIN_PASSWORD = process.env.EZA_TEST_PASSWORD || "e2e-password-123";
const MEMBER_USER = "multi-member";
const MEMBER_PASSWORD = "multi-member-password-1";
const MEMBER_PASSWORD_RESET = "multi-member-password-2";

const browser = await launchBrowser();
const admin = await launchPage(browser, { viewport: { width: 1360, height: 900 } });
const { check, report } = newChecker();
const adminApi = makeApi(admin.page);
let memberErrors = [];
let freshErrors = [];

async function searchLedger(page, query, expectedRows) {
  await page.fill(SEL.search, query);
  await page
    .waitForFunction(
      ({ rowSelector, expected }) => document.querySelectorAll(rowSelector).length === expected,
      { rowSelector: SEL.row, expected: expectedRows },
      { timeout: 20000 }
    )
    .catch(() => {});
  return page.locator(SEL.row).count();
}

try {
  await enterLibrary(admin.page);
  check("the admin account signs in", (await admin.page.locator(SEL.appShell).count()) === 1);

  // ------------------------------------------- create the member in the UI ---
  await admin.page.goto(BASE + "/account#users", { waitUntil: "domcontentloaded" });
  await admin.page.waitForSelector(SEL.usersTable, { timeout: 30000 });
  check("the admin account page shows the users panel", (await admin.page.locator(SEL.accountUsersTab).count()) === 1);
  await admin.page.fill(SEL.userName, MEMBER_USER);
  await admin.page.fill(SEL.userPassword, MEMBER_PASSWORD);
  await admin.page.selectOption(SEL.userRole, "member");
  await admin.page.click(SEL.userCreate);
  const createdMember = await admin.page
    .waitForFunction(
      ({ rowSelector, name }) => [...document.querySelectorAll(rowSelector)].some((row) => (row.textContent || "").includes(name)),
      { rowSelector: SEL.userRow, name: MEMBER_USER },
      { timeout: 20000 }
    )
    .then(() => true)
    .catch(() => false);
  const recoveryCodes = await admin.page.locator(SEL.userRecoveryCodes + " li").count();
  const newMemberRow = admin.page.locator(SEL.userRow).filter({ hasText: MEMBER_USER }).first();
  check("the admin creates the second account through the users panel", createdMember, await admin.page.locator(SEL.userActionError).innerText().catch(() => ""));
  check("the create shows ten recovery codes once", recoveryCodes === 10, String(recoveryCodes));
  check("the new account row carries the member role", /member/.test(await newMemberRow.innerText()), await newMemberRow.innerText());

  const adminListAfterCreate = await adminApi("/api/v1/admin/users");
  const member = (adminListAfterCreate.body?.users || []).find((user) => user.username === MEMBER_USER);
  check(
    "the created account appears in the admin list",
    Boolean(member) && member.role === "member" && member.disabled_at === null,
    JSON.stringify(member)
  );
  if (!member) {
    throw new Error("multiuser-smoke could not create the member account");
  }

  const memberBrowser = await launchPage(browser, { viewport: { width: 1360, height: 900 } });
  memberErrors = memberBrowser.errors;
  await enterLibraryAs(memberBrowser.page, MEMBER_USER, MEMBER_PASSWORD);
  check("the member account signs in", (await memberBrowser.page.locator(SEL.appShell).count()) === 1);
  const memberApi = makeApi(memberBrowser.page);

  await memberBrowser.page.goto(BASE + "/account#users", { waitUntil: "domcontentloaded" });
  await memberBrowser.page.waitForSelector('[data-testid="account-panel-users"]', { timeout: 20000 }).catch(() => {});
  const memberPanel = await memberBrowser.page.locator('[data-testid="account-panel-users"]').innerText().catch(() => "");
  check("a member cannot see the users table", (await memberBrowser.page.locator(SEL.usersTable).count()) === 0, memberPanel.slice(0, 120));
  check("a member sees the admin-only note", /Only an administrator/i.test(memberPanel), memberPanel.slice(0, 120));
  await memberBrowser.page.goto(BASE + "/", { waitUntil: "domcontentloaded" });
  await memberBrowser.page.waitForSelector(SEL.appShell, { timeout: 30000 });
  await memberBrowser.page.waitForSelector(SEL.search, { timeout: 30000 });

  // -------------------------------------------------- separate libraries ---
  const adminBookmark = await adminApi("/api/v1/bookmarks", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ url: "https://example.com/multi-admin-only", title: "Multiuser admin only", tags: ["multi-admin"] }),
  });
  check("the admin adds a bookmark", adminBookmark.status === 201, JSON.stringify(adminBookmark.body));
  const memberBookmark = await memberApi("/api/v1/bookmarks", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ url: "https://example.com/multi-member-only", title: "Multiuser member only", tags: ["multi-member"] }),
  });
  check("the member adds a bookmark", memberBookmark.status === 201, JSON.stringify(memberBookmark.body));

  const adminSeesOwn = await adminApi("/api/v1/bookmarks?q=" + encodeURIComponent("Multiuser admin only"));
  const adminSeesMember = await adminApi("/api/v1/bookmarks?q=" + encodeURIComponent("Multiuser member only"));
  const memberSeesOwn = await memberApi("/api/v1/bookmarks?q=" + encodeURIComponent("Multiuser member only"));
  const memberSeesAdmin = await memberApi("/api/v1/bookmarks?q=" + encodeURIComponent("Multiuser admin only"));
  check("the admin library has the admin bookmark", adminSeesOwn.body?.total === 1, JSON.stringify(adminSeesOwn.body?.total));
  check("the member library has the member bookmark", memberSeesOwn.body?.total === 1, JSON.stringify(memberSeesOwn.body?.total));
  check("the admin does not see the member bookmark", adminSeesMember.body?.total === 0, JSON.stringify(adminSeesMember.body?.total));
  check("the member does not see the admin bookmark", memberSeesAdmin.body?.total === 0, JSON.stringify(memberSeesAdmin.body?.total));

  // The browser ledger applies the same isolation.
  await admin.page.goto(BASE + "/", { waitUntil: "domcontentloaded" });
  await admin.page.waitForSelector(SEL.row, { timeout: 30000 });
  await memberBrowser.page.goto(BASE + "/", { waitUntil: "domcontentloaded" });
  await memberBrowser.page.waitForSelector(SEL.row, { timeout: 30000 });
  check("the admin ledger lists its own record", (await searchLedger(admin.page, "Multiuser admin only", 1)) === 1, await admin.page.locator(SEL.row).count());
  check("the member ledger hides the admin record", (await searchLedger(memberBrowser.page, "Multiuser admin only", 0)) === 0, await memberBrowser.page.locator(SEL.row).count());
  check("the member ledger lists its own record", (await searchLedger(memberBrowser.page, "Multiuser member only", 1)) === 1, await memberBrowser.page.locator(SEL.row).count());

  // ------------------------------------------------------ views are private ---
  const adminView = await adminApi("/api/v1/views", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      name: "Admin private view",
      kind: "graph",
      definition: {
        query: "",
        tags_shown: true,
        label_mode: "auto",
        layout_preset: "standard",
        local_depth: null,
        color_groups: [],
      },
    }),
  });
  const adminViewSlug = adminView.body?.slug;
  check("the admin creates a view", adminView.status === 201 && Boolean(adminViewSlug), JSON.stringify({ status: adminView.status, slug: adminViewSlug }));
  const memberViews = await memberApi("/api/v1/views");
  check(
    "the member view list does not contain the admin view",
    memberViews.status === 200 && !(memberViews.body?.views || []).some((view) => view.slug === adminViewSlug),
    JSON.stringify((memberViews.body?.views || []).map((view) => view.slug))
  );
  const memberReadsAdminView = await memberApi("/api/v1/views/" + adminViewSlug);
  check("the member cannot read the admin view", memberReadsAdminView.status === 404, String(memberReadsAdminView.status));
  const memberPatchesAdminView = await memberApi("/api/v1/views/" + adminViewSlug, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: "stolen" }),
  });
  check("the member cannot patch the admin view", memberPatchesAdminView.status === 404, String(memberPatchesAdminView.status));

  // ------------------------------------------------- webhooks are private ---
  const adminHook = await adminApi("/api/v1/webhooks", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      name: "Admin private hook",
      url: "https://example.com/multi-hook",
      events: ["bookmark.created"],
      enabled: true,
    }),
  });
  const adminHookId = adminHook.body?.webhook?.id;
  check("the admin creates a webhook", adminHook.status === 201 && typeof adminHookId === "number" && typeof adminHook.body?.secret === "string", JSON.stringify({ status: adminHook.status, id: adminHookId }));
  const memberHooks = await memberApi("/api/v1/webhooks");
  check(
    "the member webhook list does not contain the admin hook",
    memberHooks.status === 200 && !(memberHooks.body?.webhooks || []).some((hook) => hook.id === adminHookId),
    JSON.stringify((memberHooks.body?.webhooks || []).map((hook) => hook.id))
  );
  const memberPatchesAdminHook = await memberApi("/api/v1/webhooks/" + adminHookId, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: "stolen", url: "https://example.com/stolen", events: ["bookmark.created"], enabled: false }),
  });
  check("the member cannot patch the admin webhook", memberPatchesAdminHook.status === 404, String(memberPatchesAdminHook.status));
  const memberDeletesAdminHook = await memberApi("/api/v1/webhooks/" + adminHookId, { method: "DELETE" });
  check("the member cannot delete the admin webhook", memberDeletesAdminHook.status === 404, String(memberDeletesAdminHook.status));

  // ---------------------------------------------------- tokens are private ---
  const adminToken = await adminApi("/api/v1/tokens", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: "multi-admin-token", scopes: ["read"] }),
  });
  const adminTokenId = adminToken.body?.token_info?.id;
  const adminRawToken = adminToken.body?.token;
  check("the admin creates a token", adminToken.status === 201 && typeof adminTokenId === "number" && typeof adminRawToken === "string", JSON.stringify({ status: adminToken.status, id: adminTokenId }));
  const memberTokens = await memberApi("/api/v1/tokens");
  check(
    "the member token list does not contain the admin token",
    memberTokens.status === 200 && !(memberTokens.body?.tokens || []).some((token) => token.id === adminTokenId),
    JSON.stringify((memberTokens.body?.tokens || []).map((token) => token.id))
  );
  const memberDeletesAdminToken = await memberApi("/api/v1/tokens/" + adminTokenId, { method: "DELETE" });
  check("the member cannot delete the admin token", memberDeletesAdminToken.status === 404, String(memberDeletesAdminToken.status));
  // The admin token keeps resolving the admin database wherever it is used.
  const tokenRead = await memberBrowser.page.evaluate(async (token) => {
    const response = await fetch("/api/v1/bookmarks?q=" + encodeURIComponent("Multiuser admin only"), {
      headers: { Authorization: "Bearer " + token },
    });
    let body = null;
    try { body = await response.json(); } catch (_) { body = null; }
    return { status: response.status, total: body?.total };
  }, adminRawToken);
  check("an admin token reads the admin database", tokenRead.status === 200 && tokenRead.total === 1, JSON.stringify(tokenRead));

  // ------------------------------------------------------- shares are private ---
  const adminShare = await adminApi("/api/v1/share-links", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ scope: "bookmark", target_id: adminBookmark.body?.id, include_note: false, expires_in_days: 7 }),
  });
  const adminShareId = adminShare.body?.id;
  const adminShareUrl = adminShare.body?.url;
  check("the admin creates a share link", adminShare.status === 201 && typeof adminShareId === "number" && typeof adminShareUrl === "string", JSON.stringify({ status: adminShare.status, id: adminShareId }));
  const memberShares = await memberApi("/api/v1/share-links");
  check(
    "the member share list does not contain the admin share",
    memberShares.status === 200 && !(memberShares.body?.shares || []).some((share) => share.id === adminShareId),
    JSON.stringify((memberShares.body?.shares || []).map((share) => share.id))
  );
  const memberDeletesAdminShare = await memberApi("/api/v1/share-links/" + adminShareId, { method: "DELETE" });
  check("the member cannot revoke the admin share", memberDeletesAdminShare.status === 404, String(memberDeletesAdminShare.status));
  const publicShare = await memberBrowser.page.evaluate(async (path) => {
    const response = await fetch(path);
    return { status: response.status, text: (await response.text()).slice(0, 80) };
  }, new URL(adminShareUrl).pathname);
  check("the share link itself stays public", publicShare.status === 200, JSON.stringify(publicShare));

  // ------------------------------------------------ disable blocks login ---
  await admin.page.goto(BASE + "/account#users", { waitUntil: "domcontentloaded" });
  await admin.page.waitForSelector(SEL.usersTable, { timeout: 30000 });
  const memberRow = admin.page.locator(SEL.userRow).filter({ hasText: MEMBER_USER }).first();
  await memberRow.locator(SEL.userDisable).click();
  const disabledInUi = await admin.page
    .waitForFunction(
      ({ rowSelector, name }) => {
        const row = [...document.querySelectorAll(rowSelector)].find((candidate) => (candidate.textContent || "").includes(name));
        return Boolean(row && (row.textContent || "").includes("disabled"));
      },
      { rowSelector: SEL.userRow, name: MEMBER_USER },
      { timeout: 20000 }
    )
    .then(() => true)
    .catch(() => false);
  const disabledList = await adminApi("/api/v1/admin/users");
  const disabledMember = (disabledList.body?.users || []).find((user) => user.id === member.id);
  check(
    "the admin disables the member through the users panel",
    disabledInUi && typeof disabledMember?.disabled_at === "number",
    JSON.stringify(disabledMember)
  );

  await memberBrowser.page.goto(BASE + "/", { waitUntil: "domcontentloaded" });
  const kicked = await memberBrowser.page
    .waitForURL((url) => url.pathname.startsWith("/login"), { timeout: 20000 })
    .then(() => true)
    .catch(() => false);
  check("a disabled account loses its browser session", kicked, memberBrowser.page.url());

  const fresh = await launchPage(browser, { viewport: { width: 1200, height: 800 } });
  freshErrors = fresh.errors;
  await fresh.page.goto(BASE + "/login", { waitUntil: "domcontentloaded" });
  await fresh.page.fill("#username", MEMBER_USER);
  await fresh.page.fill("#password", MEMBER_PASSWORD);
  await fresh.page.click("#password-login");
  const loginFailed = await fresh.page
    .waitForFunction(
      () => {
        const node = document.querySelector("#auth-error");
        return Boolean(node && (node.textContent || "").trim().length > 0);
      },
      null,
      { timeout: 30000 }
    )
    .then(() => true)
    .catch(() => false);
  const loginError = (await fresh.page.locator("#auth-error").innerText().catch(() => "")).trim();
  check("a disabled account cannot sign in", loginFailed && /username or password/i.test(loginError), loginError || fresh.page.url());

  // Recovery needs the account name and hides whether it exists.
  const recoveryMissing = await fresh.page.evaluate(async () => {
    const response = await fetch("/api/recovery/redeem", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code: "not-a-code" }),
    });
    let body = null;
    try { body = await response.json(); } catch (_) { body = null; }
    return { status: response.status, body };
  });
  check("recovery without a username is a 400", recoveryMissing.status === 400, JSON.stringify(recoveryMissing));
  const recoveryUnknown = await fresh.page.evaluate(async () => {
    const response = await fetch("/api/recovery/redeem", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username: "no-such-account", code: "not-a-code" }),
    });
    let body = null;
    try { body = await response.json(); } catch (_) { body = null; }
    return { status: response.status, body };
  });
  check(
    "an unknown recovery account is a generic 400",
    recoveryUnknown.status === 400 && recoveryUnknown.body?.error?.code === "bad_code",
    JSON.stringify(recoveryUnknown)
  );

  await admin.page.goto(BASE + "/account#users", { waitUntil: "domcontentloaded" });
  await admin.page.waitForSelector(SEL.usersTable, { timeout: 30000 });
  const disabledRow = admin.page.locator(SEL.userRow).filter({ hasText: MEMBER_USER }).first();
  await disabledRow.locator(SEL.userEnable).click();
  const enabledInUi = await admin.page
    .waitForFunction(
      ({ rowSelector, name }) => {
        const row = [...document.querySelectorAll(rowSelector)].find((candidate) => (candidate.textContent || "").includes(name));
        return Boolean(row && !(row.textContent || "").includes("disabled"));
      },
      { rowSelector: SEL.userRow, name: MEMBER_USER },
      { timeout: 20000 }
    )
    .then(() => true)
    .catch(() => false);
  const enabledList = await adminApi("/api/v1/admin/users");
  const enabledMember = (enabledList.body?.users || []).find((user) => user.id === member.id);
  check(
    "the admin re-enables the member through the users panel",
    enabledInUi && enabledMember?.disabled_at === null,
    JSON.stringify(enabledMember)
  );

  const resetMember = await adminApi("/api/v1/admin/users/" + member.id + "/password", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ password: MEMBER_PASSWORD_RESET }),
  });
  check("the admin sets a temporary password", resetMember.status === 200 && resetMember.body?.ok === true, JSON.stringify({ status: resetMember.status }));
  await fresh.page.goto(BASE + "/login", { waitUntil: "domcontentloaded" });
  await fresh.page.fill("#username", MEMBER_USER);
  await fresh.page.fill("#password", MEMBER_PASSWORD_RESET);
  await fresh.page.click("#password-login");
  const relogin = await fresh.page
    .waitForSelector(SEL.appShell, { timeout: 30000 })
    .then(() => true)
    .catch(() => false);
  check("an enabled account signs in with the reset password", relogin, fresh.page.url());

  // ------------------------------------------------------- console noise ---
  const unexpected = [...admin.errors, ...memberErrors, ...freshErrors].filter((entry) => !/400|401|403|404/.test(entry));
  check("no unexpected console errors", unexpected.length === 0, unexpected.slice(0, 3).join(" | ").slice(0, 400));
} catch (error) {
  check("unexpected error", false, String(error && error.stack ? error.stack : error));
} finally {
  await browser.close();
}

report([...admin.errors, ...memberErrors, ...freshErrors]);
