/**
 * Auth ceremony suite (plan todo 13). Drives the REAL browser WebAuthn API
 * through a CDP virtual authenticator against the app on port 8000
 * (auth-e2e.db), which the playwright.config.ts webServer wipes at boot.
 *
 * Scenarios (all headless, all through the app's own HTTP surface):
 *
 * 1. first-run lifecycle: 401 login page -> setup register -> codes -> login
 *    -> session persists -> logout -> login again.
 * 2. returning user: clearing cookies yields a 401 whose BODY IS the login
 *    page; the usernameless ceremony restores the session.
 * 3. dual passkey: two resident credentials, each logs in independently
 *    (proven by per-credential last_used_at).
 * 4. BE-gated signCount leniency: an inflated stored counter (stale/regressed)
 *    never locks the account, and a single-device credential's counter is
 *    left untouched.
 * 5. recovery redeem -> re-enroll: a code obtained from the app's API opens a
 *    recovery-scoped session (pinned to /setup), re-registration restores a
 *    normal session, and the NEW credential logs in.
 *
 * These tests share one server/DB, so they run serially and in this order.
 */

import { test, expect, AUTH_E2E_DB } from "./fixtures";
import {
  addVirtualCredential,
  bumpSignCount,
  gotoStatus,
  loginViaCeremony,
  readCredentials,
  readCsrfToken,
  registerViaCeremony,
  seedCredential,
} from "./fixtures";

test.describe.configure({ mode: "serial" });

test("first-run lifecycle: register, login, session persists, logout, login again", async ({
  page,
  webauthn,
}) => {
  // Fresh DB: an unauthenticated HTML request is a 401 whose body is the
  // usernameless login page.
  expect(await gotoStatus(page, "/")).toBe(401);
  await expect(page.locator("h1")).toHaveText("Bookmarks");
  await expect(page.locator("#login")).toBeVisible();

  // First-run setup ceremony -> one-time recovery codes via the setup API.
  expect(await gotoStatus(page, "/setup")).toBe(200);
  await expect(page.locator("#register")).toBeVisible();
  const registration = await registerViaCeremony(page);
  expect(registration.status).toBe(200);
  expect(registration.codes).toHaveLength(10);

  // Setup is now claimed: /setup is gone.
  expect(await gotoStatus(page, "/setup")).toBe(404);

  // The registration opened a session and it persists across navigation.
  expect(await gotoStatus(page, "/")).toBe(200);
  await expect(page.locator("#search")).toBeVisible();

  // Explicit usernameless login (fresh context cookies) — this also sets the
  // non-httpOnly csrf cookie.
  await page.context().clearCookies();
  expect((await loginViaCeremony(page, registration.credentialId)).status).toBe(200);
  expect(await gotoStatus(page, "/")).toBe(200);

  // Logout requires the session's CSRF token and clears both cookies.
  const csrf = await readCsrfToken(page);
  expect(csrf).not.toBe("");
  const logout = await page.evaluate(
    async (token) =>
      (
        await fetch("/api/auth/logout", {
          method: "POST",
          headers: { "X-CSRF-Token": token },
        })
      ).status,
    csrf,
  );
  expect(logout).toBe(200);
  expect(await gotoStatus(page, "/")).toBe(401);

  // Login again after logout.
  expect((await loginViaCeremony(page, registration.credentialId)).status).toBe(200);
  expect(await gotoStatus(page, "/")).toBe(200);
});

test("returning user: / is a 401 whose body IS the login page; ceremony restores the session", async ({
  page,
  webauthn,
}) => {
  // The browser holds a fresh authenticator; seed it with a credential whose
  // public key is already in the app DB (a "returning user"'s passkey).
  const seed = seedCredential(AUTH_E2E_DB, "/tmp/e2e-seed-returning.json", true);
  await addVirtualCredential(webauthn, seed);

  await page.goto("/");
  // 401 body is the login page, not a JSON error.
  await expect(page.locator("h1")).toHaveText("Bookmarks");
  await expect(page.locator("#login")).toBeVisible();

  // Usernameless ceremony through the page's own button.
  await page.locator("#login").click();
  await page.waitForLoadState("networkidle");
  expect(await gotoStatus(page, "/")).toBe(200);
  await expect(page.locator("#search")).toBeVisible();
});

test("dual passkey: each resident credential logs in independently", async ({
  page,
  webauthn,
}) => {
  const a = seedCredential(AUTH_E2E_DB, "/tmp/e2e-seed-dual-a.json", true, 1);
  const b = seedCredential(AUTH_E2E_DB, "/tmp/e2e-seed-dual-b.json", true, 2);
  await addVirtualCredential(webauthn, a);
  await addVirtualCredential(webauthn, b);

  await gotoStatus(page, "/");
  expect((await loginViaCeremony(page, a.credentialId)).status).toBe(200);
  // The assertion's sign-count advance is only recorded for the credential
  // that actually signed: A moved 1 -> 2, B is untouched.
  let rows = readCredentials(AUTH_E2E_DB);
  expect(rows[a.credentialId].signCount).toBe(2);
  expect(rows[b.credentialId].signCount).toBe(1);

  await page.context().clearCookies();
  expect((await loginViaCeremony(page, b.credentialId)).status).toBe(200);
  rows = readCredentials(AUTH_E2E_DB);
  expect(rows[b.credentialId].signCount).toBe(2);
});

test("BE-gated signCount leniency: a stale counter never locks the account", async ({
  page,
  webauthn,
}) => {
  // Single-device (backup_eligible=0) credential: the strictest case — a
  // counter regression must still not lock the user out.
  const seed = seedCredential(AUTH_E2E_DB, "/tmp/e2e-seed-signcount.json", false);
  await addVirtualCredential(webauthn, seed);

  await gotoStatus(page, "/");
  expect((await loginViaCeremony(page, seed.credentialId)).status).toBe(200);

  // Simulate a stale/regressed counter in the store.
  bumpSignCount(AUTH_E2E_DB, 100_000);

  // Login still succeeds (no hard failure / no account lock).
  expect((await loginViaCeremony(page, seed.credentialId)).status).toBe(200);
  // And for a single-device credential the regressed counter is left as-is.
  const rows = readCredentials(AUTH_E2E_DB);
  expect(rows[seed.credentialId].signCount).toBe(100_000);
});

test("recovery: a code from the app's API redeems into a scoped session and re-enrollment restores access", async ({
  page,
  webauthn,
}) => {
  const seed = seedCredential(AUTH_E2E_DB, "/tmp/e2e-seed-recovery.json", true);
  await addVirtualCredential(webauthn, seed);

  // Log in, then rotate the recovery codes (authed, CSRF-protected).
  await gotoStatus(page, "/");
  expect((await loginViaCeremony(page, seed.credentialId)).status).toBe(200);
  const codes = await page.evaluate(async (csrf) => {
    const resp = await fetch("/api/recovery/regenerate", {
      method: "POST",
      headers: { "X-CSRF-Token": csrf },
    });
    return ((await resp.json()) as { codes: string[] }).codes;
  }, await readCsrfToken(page));
  expect(codes).toHaveLength(10);

  // Redeem a code: revokes every credential and opens a recovery-scoped
  // session pinned to the re-enrollment flow.
  await page.context().clearCookies();
  const redeem = await page.evaluate(async (code) => {
    const resp = await fetch("/api/recovery/redeem", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code }),
    });
    return { status: resp.status, body: (await resp.json()) as { next?: string } };
  }, codes[0]);
  expect(redeem.status).toBe(200);
  expect(redeem.body.next).toBe("/setup");

  // A recovery-scoped session is FORBIDDEN on normal routes...
  expect(await gotoStatus(page, "/")).toBe(403);
  await expect(page.locator("h1")).toHaveText("Passkey recovery");
  // ...and allowed on the re-enrollment page.
  expect(await gotoStatus(page, "/setup")).toBe(200);

  // Re-enroll: a brand-new resident credential replaces the revoked ones and
  // a normal-scoped session is restored.
  const reEnroll = await registerViaCeremony(page);
  expect(reEnroll.status).toBe(200);
  expect(await gotoStatus(page, "/")).toBe(200);

  // The NEW credential alone can log in.
  await page.context().clearCookies();
  expect((await loginViaCeremony(page, reEnroll.credentialId)).status).toBe(200);
  expect(await gotoStatus(page, "/")).toBe(200);
});
