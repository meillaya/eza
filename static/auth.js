// Password setup, sign-in, optional passkey two-factor, and recovery for the
// server-rendered auth pages. The legacy passkey sign-in remains for libraries
// claimed before passwords. No inline scripts: this file is served from
// /assets/auth.js.

const $ = (sel) => document.querySelector(sel);

function b64urlToBuf(value) {
  const s = value.replace(/-/g, "+").replace(/_/g, "/");
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const bin = atob(s + pad);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes.buffer;
}

function bufToB64url(buf) {
  const bytes = new Uint8Array(buf);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function parseCreationOptions(options) {
  if (window.PublicKeyCredential && PublicKeyCredential.parseCreationOptionsFromJSON) {
    return PublicKeyCredential.parseCreationOptionsFromJSON(options);
  }
  const o = { ...options };
  o.challenge = b64urlToBuf(options.challenge);
  o.user = { ...options.user, id: b64urlToBuf(options.user.id) };
  if (options.excludeCredentials) {
    o.excludeCredentials = options.excludeCredentials.map((c) => ({ ...c, id: b64urlToBuf(c.id) }));
  }
  return o;
}

function parseRequestOptions(options) {
  if (window.PublicKeyCredential && PublicKeyCredential.parseRequestOptionsFromJSON) {
    return PublicKeyCredential.parseRequestOptionsFromJSON(options);
  }
  const o = { ...options };
  o.challenge = b64urlToBuf(options.challenge);
  if (options.allowCredentials) {
    o.allowCredentials = options.allowCredentials.map((c) => ({ ...c, id: b64urlToBuf(c.id) }));
  }
  return o;
}

function credentialJSON(credential) {
  if (credential.toJSON) return credential.toJSON();
  const r = credential.response;
  const out = {
    id: credential.id,
    rawId: bufToB64url(credential.rawId),
    type: credential.type,
    clientExtensionResults: credential.getClientExtensionResults
      ? credential.getClientExtensionResults()
      : {},
    response: {},
  };
  if (r.clientDataJSON !== undefined) out.response.clientDataJSON = bufToB64url(r.clientDataJSON);
  if (r.attestationObject !== undefined) out.response.attestationObject = bufToB64url(r.attestationObject);
  if (r.authenticatorData !== undefined) out.response.authenticatorData = bufToB64url(r.authenticatorData);
  if (r.signature !== undefined) out.response.signature = bufToB64url(r.signature);
  if (r.userHandle !== undefined && r.userHandle !== null) out.response.userHandle = bufToB64url(r.userHandle);
  return out;
}

async function postJSON(url, body) {
  const csrf = document.cookie.split("; ").find((c) => c.startsWith("eza_csrf="))?.split("=")[1] || "";
  const headers = { "Content-Type": "application/json" };
  if (csrf) headers["X-CSRF-Token"] = csrf;
  const resp = await fetch(url, {
    method: "POST",
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await resp.json().catch(() => ({}));
  if (!resp.ok) {
    const error = new Error((data.error && data.error.message) || "Request failed (" + resp.status + ")");
    error.status = resp.status;
    error.code = (data.error && data.error.code) || "";
    throw error;
  }
  return data;
}

function showError(message) {
  const el = $("#auth-error");
  if (el) el.textContent = message;
}

// Passkey ceremonies need a secure origin and a hostname as the WebAuthn
// relying-party ID; an IP literal fails before the browser prompt opens.
function passkeysUnavailable() {
  if (!window.isSecureContext) {
    return "Passkeys need a secure origin: https or http://localhost.";
  }
  if (!window.PublicKeyCredential || !navigator.credentials) {
    return "This browser does not offer passkeys.";
  }
  const host = window.location.hostname;
  const isIpLiteral = /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/.test(host) || host.startsWith("[");
  if (isIpLiteral) {
    return "Passkeys need a hostname, not an IP address.";
  }
  return "";
}

function blockIfPasskeysUnavailable() {
  const reason = passkeysUnavailable();
  if (reason) showError(reason);
  return reason !== "";
}

// Two-factor sign-in cannot fall back to the password; a recovery code is the
// only other way in.
function secondFactorUnavailable() {
  if (!window.isSecureContext) {
    return "The passkey step needs a secure origin: https or http://localhost.";
  }
  if (!window.PublicKeyCredential || !navigator.credentials) {
    return "This browser does not offer passkeys.";
  }
  const host = window.location.hostname;
  const isIpLiteral = /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/.test(host) || host.startsWith("[");
  if (isIpLiteral) {
    return "The passkey step needs a hostname, not an IP address.";
  }
  return "";
}

// ---------------------------------------------------------------------------
// Password flows
// ---------------------------------------------------------------------------

let loginInFlight = false;

async function doPasswordLogin(event) {
  event.preventDefault();
  if (loginInFlight) return;
  loginInFlight = true;
  try {
    showError("");
    const username = $("#username").value.trim();
    const password = $("#password").value;
    if (!username || !password) {
      showError("Enter the username and password.");
      return;
    }
    const result = await postJSON("/api/auth/login", { username, password });
    if (result.requires_2fa) {
      await doPasskeySecondFactor();
      return;
    }
    window.location.href = result.redirect || "/";
  } catch (e) {
    showError(e.message || String(e));
  } finally {
    loginInFlight = false;
  }
}

// The password was right, but the account also asks for a passkey. The server
// holds a short-lived pending sign-in; one assertion swaps it for the session.
async function doPasskeySecondFactor() {
  const unavailable = secondFactorUnavailable();
  if (unavailable) {
    showError("Passkey two-factor is on for this account. " + unavailable + " A recovery code still signs in.");
    return;
  }
  try {
    const options = await postJSON("/api/auth/passkey/options");
    const credential = await navigator.credentials.get({ publicKey: parseRequestOptions(options) });
    const result = await postJSON("/api/auth/passkey/verify", credentialJSON(credential));
    window.location.href = result.redirect || "/";
  } catch (e) {
    showError(secondFactorMessage(e));
  }
}

function secondFactorMessage(error) {
  if (!error) return "The passkey check did not finish. Enter the password again.";
  if (error.code === "pending_required") {
    return "The sign-in attempt expired. Enter the password again.";
  }
  if (error.code === "2fa_not_required") {
    return "The account no longer asks for a passkey. Reload and sign in again.";
  }
  if (error.name === "NotAllowedError") {
    return "The passkey prompt was dismissed or timed out. Enter the password again.";
  }
  if (error.name === "InvalidStateError") {
    return "No usable passkey in this browser. Try another passkey, or a recovery code.";
  }
  if (error.name === "SecurityError") {
    return "The browser refused the passkey step for this origin. Open eza on the hostname you normally use.";
  }
  return error.message || String(error);
}

let codesWired = false;

function showCodes(codes, redirect) {
  const section = $("#recovery");
  if (!section) {
    window.location.href = redirect || "/";
    return;
  }
  showError("");
  section.hidden = false;
  $("#codes").textContent = codes.join("\n");
  if (codesWired) return;
  codesWired = true;
  $("#copy-codes")?.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(codes.join("\n"));
      $("#copy-codes").textContent = "Copied";
    } catch (_) {
      showError("Copy failed. Select the codes manually.");
    }
  });
  $("#continue")?.addEventListener("click", () => {
    window.location.href = redirect || "/";
  });
}

async function doPasswordSetup(event) {
  event.preventDefault();
  try {
    showError("");
    const username = $("#username").value.trim();
    const password = $("#password").value;
    const confirm = $("#confirm-password").value;
    if (!username) {
      showError("Choose a username.");
      return;
    }
    if (password.length < 10) {
      showError("Use a password of at least ten characters.");
      return;
    }
    if (password !== confirm) {
      showError("The passwords do not match.");
      return;
    }
    const result = await postJSON("/api/setup/password", { username, password, confirm });
    showCodes(result.codes || [], result.redirect || "/");
  } catch (e) {
    showError(e.message || String(e));
  }
}

async function doRecover() {
  try {
    showError("");
    const username = $("#recover-username").value.trim();
    if (!username) {
      showError("Enter the username to recover.");
      return;
    }
    const code = $("#recovery-code").value.trim();
    if (!code) {
      showError("Enter a recovery code.");
      return;
    }
    const result = await postJSON("/api/recovery/redeem", { username, code });
    window.location.href = result.redirect || "/setup";
  } catch (e) {
    showError(e.message || String(e));
  }
}

// ---------------------------------------------------------------------------
// Legacy passkey flows
// ---------------------------------------------------------------------------

async function doPasskeyLogin() {
  try {
    showError("");
    if (blockIfPasskeysUnavailable()) return;
    const options = await postJSON("/api/auth/options");
    const credential = await navigator.credentials.get({ publicKey: parseRequestOptions(options) });
    const result = await postJSON("/api/auth/verify", credentialJSON(credential));
    window.location.href = result.redirect || "/";
  } catch (e) {
    showError(e.message || String(e));
  }
}

async function doAddPasskey() {
  try {
    showError("");
    if (blockIfPasskeysUnavailable()) return;
    const options = await postJSON("/api/v1/account/passkeys/options");
    const credential = await navigator.credentials.create({ publicKey: parseCreationOptions(options) });
    await postJSON("/api/v1/account/passkeys/verify", credentialJSON(credential));
    window.location.href = "/account";
  } catch (e) {
    showError(e.message || String(e));
  }
}

const page = document.querySelector("[data-page]")?.dataset.page;
const passkeyPage = page === "passkey-login" || page === "add-passkey";
if (passkeyPage) {
  const reason = passkeysUnavailable();
  if (reason) showError(reason);
}
if (page === "login") $("#auth-form")?.addEventListener("submit", doPasswordLogin);
if (page === "setup" || page === "recovery-setup") $("#auth-form")?.addEventListener("submit", doPasswordSetup);
if (page === "passkey-login") $("#passkey-login")?.addEventListener("click", doPasskeyLogin);
if (page === "recover") $("#redeem")?.addEventListener("click", doRecover);
if (page === "add-passkey") $("#passkey-add")?.addEventListener("click", doAddPasskey);
