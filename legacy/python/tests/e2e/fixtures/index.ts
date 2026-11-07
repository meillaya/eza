/**
 * e2e fixture layer (contract §1.5): specs NEVER import raw @playwright/test.
 *
 * This module is the single seam for browser capabilities. It exports:
 *
 * - `test` / `expect` — the extended primitives every spec imports.
 * - `enableWebAuthn(context, page)` — CDP virtual-authenticator setup
 *   (WebAuthn.enable + addVirtualAuthenticator, ctap2/internal resident key,
 *   UV + user-verified true, automatic presence simulation) so passkey
 *   ceremonies run headless with no UI interaction.
 * - The `webauthn` fixture — installs a fresh virtual authenticator per test
 *   when a spec requests it.
 * - Ceremony helpers (`registerViaCeremony`, `loginViaCeremony`) that drive
 *   the real browser WebAuthn API through the app's own /api/setup|auth
 *   endpoints, with an optional `allowCredential` for multi-passkey logins.
 * - DB seeding helpers (`seedCredential`, `readCredentials`,
 *   `bumpSignCount`) — the harness needs credentials whose private keys it
 *   also holds, so it inserts a matched keypair into the app DB and hands the
 *   private key to CDP `WebAuthn.addCredential`.
 */

import { execSync } from "node:child_process";
import * as fs from "node:fs";
import {
  test as base,
  expect,
  type BrowserContext,
  type CDPSession,
  type Page,
} from "@playwright/test";

export { expect };

// The auth-ceremony server owns its own DB (see playwright.config.ts).
export const AUTH_E2E_DB = process.env.AUTH_E2E_DB ?? "/work/e2e/auth-e2e.db";

export const E2E_WORKDIR = process.cwd();

// ---------------------------------------------------------------------------
// CDP WebAuthn virtual authenticator
// ---------------------------------------------------------------------------

export type WebAuthnState = {
  cdp: CDPSession;
  authenticatorId: string;
};

/**
 * Attach a CTAP2 internal virtual authenticator to the page. With
 * PUBLIC_ORIGIN=http://localhost:8000 the RP ID is "localhost"; credentials
 * created here bind to that RP automatically. `automaticPresenceSimulation`
 * grants user presence without any dialog, and `isUserVerified: true` meets
 * the server's UV=REQUIRED policy.
 */
export async function enableWebAuthn(
  context: BrowserContext,
  page: Page,
): Promise<WebAuthnState> {
  const cdp = await context.newCDPSession(page);
  await cdp.send("WebAuthn.enable", { enableUI: false });
  const { authenticatorId } = await cdp.send("WebAuthn.addVirtualAuthenticator", {
    options: {
      protocol: "ctap2",
      transport: "internal",
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      automaticPresenceSimulation: true,
    },
  });
  return { cdp, authenticatorId };
}

export const test = base.extend<{ webauthn: WebAuthnState }>({
  webauthn: async ({ context, page }, use) => {
    await use(await enableWebAuthn(context, page));
  },
});

// ---------------------------------------------------------------------------
// Ceremony helpers (run inside the page: real navigator.credentials calls)
// ---------------------------------------------------------------------------

/** The app's first-run registration ceremony; returns codes + credential id. */
export function registerViaCeremony(page: Page): Promise<{
  status: number;
  codes: string[];
  credentialId: string;
}> {
  return page.evaluate(async () => {
    const optsResp = await fetch("/api/setup/options", { method: "POST" });
    if (optsResp.status !== 200) {
      return { status: optsResp.status, codes: [], credentialId: "" };
    }
    const options = await optsResp.json();
    const credential = await navigator.credentials.create({
      publicKey: PublicKeyCredential.parseCreationOptionsFromJSON(options),
    });
    const verifyResp = await fetch("/api/setup/verify", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(credential),
    });
    const result = (await verifyResp.json()) as { codes?: string[] };
    return {
      status: verifyResp.status,
      codes: result.codes ?? [],
      credentialId: credential.id,
    };
  });
}

/**
 * Usernameless login ceremony. When `allowCredentialId` (base64url) is given
 * it is injected into the parsed options so a specific passkey is used — the
 * server always issues an empty allow-list, so this only selects WHICH
 * credential signs, which is exactly what multi-passkey tests need.
 */
export function loginViaCeremony(
  page: Page,
  allowCredentialId?: string,
): Promise<{ status: number }> {
  return page.evaluate(async (wantCred) => {
    const options = await (await fetch("/api/auth/options", { method: "POST" })).json();
    const parsed = PublicKeyCredential.parseRequestOptionsFromJSON(options);
    if (wantCred) {
      const bin = Uint8Array.from(
        atob(wantCred.replace(/-/g, "+").replace(/_/g, "/")),
        (c) => c.charCodeAt(0),
      );
      parsed.allowCredentials = [{ type: "public-key", id: bin }];
    }
    const credential = await navigator.credentials.get({ publicKey: parsed });
    const verifyResp = await fetch("/api/auth/verify", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(credential),
    });
    return { status: verifyResp.status };
  }, allowCredentialId ?? null);
}

/** Read the CSRF token the login ceremony stashed in the non-httpOnly cookie. */
export function readCsrfToken(page: Page): Promise<string> {
  return page.evaluate(() => {
    const cookie = document.cookie
      .split("; ")
      .find((c) => c.startsWith("csrf_token="));
    return cookie ? cookie.slice("csrf_token=".length) : "";
  });
}

/**
 * page.goto() that returns the HTTP status even for 4xx/5xx responses.
 * Some Playwright builds reject non-2xx navigations; this never throws.
 */
export async function gotoStatus(page: Page, url: string): Promise<number> {
  try {
    const resp = await page.goto(url);
    return resp?.status() ?? 0;
  } catch {
    return page.evaluate(async (u) => (await fetch(u)).status, url);
  }
}

// ---------------------------------------------------------------------------
// DB seeding (harness credentials the virtual authenticator can sign with)
// ---------------------------------------------------------------------------

export type SeededCredential = {
  /** CDP `binary` field: STANDARD base64 of the raw credential id bytes. */
  credentialId: string;
  /** CDP `binary` field: standard base64 of the user handle bytes. */
  userHandle: string;
  /** CDP `binary` field: standard base64 of the PKCS8 DER private key. */
  privateKey: string;
  signCount: number;
  backupEligibility: boolean;
};

export type CredentialRow = {
  credentialId: string;
  signCount: number;
  backupEligibility: boolean;
  lastUsedAt: number | null;
};

function runSeed(args: string[]): string {
  return execSync(`uv run python tests/e2e/helpers/seed_credential.py ${args.join(" ")}`, {
    cwd: E2E_WORKDIR,
    env: {
      ...process.env,
      // Same container-local venv the webServer command syncs into.
      UV_PROJECT_ENVIRONMENT: process.env.UV_PROJECT_ENVIRONMENT ?? "/tmp/bookmarks-e2e-venv",
    },
    stdio: "pipe",
    encoding: "utf8",
  });
}

/** Generate a matched keypair, insert it into the app DB, return it. */
export function seedCredential(
  dbPath: string,
  outFile: string,
  backupEligibility = true,
  userHandle = 1,
): SeededCredential {
  const stdout = runSeed([
    "--db",
    `"${dbPath}"`,
    "--be",
    backupEligibility ? "1" : "0",
    "--user-handle",
    String(userHandle),
  ]);
  const result = JSON.parse(stdout) as SeededCredential;
  fs.writeFileSync(outFile, JSON.stringify(result));
  return result;
}

/** Inject a seeded credential into the virtual authenticator (RP "localhost"). */
export async function addVirtualCredential(
  webauthn: WebAuthnState,
  seed: SeededCredential,
): Promise<void> {
  await webauthn.cdp.send("WebAuthn.addCredential", {
    authenticatorId: webauthn.authenticatorId,
    credential: {
      credentialId: seed.credentialId,
      isResidentCredential: true,
      rpId: "localhost",
      privateKey: seed.privateKey,
      signCount: seed.signCount,
      userHandle: seed.userHandle,
      backupEligibility: seed.backupEligibility,
      backupState: seed.backupEligibility,
    },
  });
}

/** Read every credential row (keyed by base64url id) from the app DB. */
export function readCredentials(dbPath: string): Record<string, CredentialRow> {
  const stdout = runSeed(["--db", `"${dbPath}"`, "list"]);
  const result = JSON.parse(stdout) as { credentials: CredentialRow[] };
  return Object.fromEntries(result.credentials.map((c) => [c.credentialId, c]));
}

/** Inflate every stored sign_count — simulates a stale/regressed counter. */
export function bumpSignCount(dbPath: string, signCount: number): void {
  runSeed(["--db", `"${dbPath}"`, "bump", "--sign-count", String(signCount)]);
}
