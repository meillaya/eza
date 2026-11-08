// WebAuthn ceremonies for the server-rendered auth pages.
// No inline scripts: this file is served from /assets/auth.js.

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
  if (!resp.ok) throw new Error((data.error && data.error.message) || "Request failed (" + resp.status + ")");
  return data;
}

function showError(message) {
  const el = $("#auth-error");
  if (el) el.textContent = message;
}

// Passkeys need a secure origin. Browsers treat localhost and 127.0.0.1 as
// secure, but a LAN address or a plain http hostname is not. Say that plainly
// instead of surfacing the browser's SecurityError.
function passkeysUnavailable() {
  if (!window.isSecureContext) {
    return "Passkeys need a secure origin. Open eza over https, or on http://localhost, then try again. A recovery code works on any origin.";
  }
  if (!window.PublicKeyCredential || !navigator.credentials) {
    return "This browser does not offer passkeys. Use a recovery code instead.";
  }
  return "";
}

function blockIfPasskeysUnavailable() {
  const reason = passkeysUnavailable();
  if (reason) showError(reason);
  return reason !== "";
}

async function doLogin() {
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

async function doSetup() {
  try {
    showError("");
    if (blockIfPasskeysUnavailable()) return;
    const options = await postJSON("/api/setup/options");
    const credential = await navigator.credentials.create({ publicKey: parseCreationOptions(options) });
    const result = await postJSON("/api/setup/verify", credentialJSON(credential));
    const codes = result.codes || [];
    $("#auth-error").textContent = "";
    const section = $("#recovery");
    section.hidden = false;
    $("#codes").textContent = codes.join("\n");
    $("#passkey-setup").hidden = true;
    $("#copy-codes").addEventListener("click", async () => {
      try { await navigator.clipboard.writeText(codes.join("\n")); $("#copy-codes").textContent = "Copied"; }
      catch (_) { showError("Copy failed. Select the codes manually."); }
    });
    $("#continue").addEventListener("click", () => { window.location.href = result.redirect || "/"; });
  } catch (e) {
    showError(e.message || String(e));
  }
}

async function doRecover() {
  try {
    showError("");
    const code = $("#recovery-code").value.trim();
    if (!code) { showError("Enter a recovery code."); return; }
    const result = await postJSON("/api/recovery/redeem", { code });
    window.location.href = result.redirect || "/setup";
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
if (page && !window.isSecureContext) {
  showError("Passkeys need a secure origin. Open eza over https, or on http://localhost. A recovery code works on any origin.");
}
if (page === "login") $("#passkey-login")?.addEventListener("click", doLogin);
if (page === "setup") $("#passkey-setup")?.addEventListener("click", doSetup);
if (page === "recover") $("#redeem")?.addEventListener("click", doRecover);
if (page === "add-passkey") $("#passkey-add")?.addEventListener("click", doAddPasskey);
