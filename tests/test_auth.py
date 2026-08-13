"""Usernameless login + sessions + CSRF + global route guard tests (todo 10).

The usernameless passkey ceremony itself is deferred to todo 13's Playwright
harness; these tests exercise the full API shape and the security matrix at
TestClient level:

- POST /api/auth/options: usernameless (``allowCredentials=[]``), UV=REQUIRED,
  rpId from config, challenge persisted single-use with a 5-minute TTL.
- POST /api/auth/verify: full assertion verification end-to-end (the same
  in-process key-signing technique as test_setup.py), normal-scoped session +
  httpOnly/SameSite=Strict session cookie + non-httpOnly csrf_token cookie,
  BE-gated lenient sign-count updates.
- POST /api/auth/logout: deletes the session row and clears both cookies.
- The GLOBAL middleware: 401 JSON for unauthenticated API, 401-with-login-page
  for HTML, CSRF enforcement on mutating writes, recovery-scoped-session
  rejection on every route except /api/setup/*, GET /setup and
  POST /api/recovery/redeem.
- Route-scan: every registered route is either exempt-listed or returns 401
  without a session — the load-bearing guarantee for routes added in later
  waves.
"""

from __future__ import annotations

import hashlib
import json
import re
import secrets
import time
from base64 import urlsafe_b64decode, urlsafe_b64encode
from typing import Any

import cbor2
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from app import auth, config, db
from app.main import app


def _b64url(data: bytes) -> str:
    return urlsafe_b64encode(data).rstrip(b"=").decode()


def _b64url_decode(data: str) -> bytes:
    return urlsafe_b64decode(data + "=" * (-len(data) % 4))


def _cose_public_key(private_key: ec.EllipticCurvePrivateKey) -> bytes:
    """COSE-encoded ECDSA P-256 public key (ES256, alg -7) for a key pair."""
    public_numbers = private_key.public_key().public_numbers()
    x = public_numbers.x.to_bytes(32, "big")
    y = public_numbers.y.to_bytes(32, "big")
    return cbor2.dumps({1: 2, 3: -7, -1: 1, -2: x, -3: y})


def _flags(*, attested: bool, user_verified: bool, backup_eligible: bool, backup_state: bool) -> int:
    flags = 0x01  # UP
    if attested:
        flags |= 0x40  # AT
    if user_verified:
        flags |= 0x04  # UV
    if backup_eligible:
        flags |= 0x08  # BE
    if backup_state:
        flags |= 0x10  # BS
    return flags


def build_registration_response(
    challenge: bytes,
    private_key: ec.EllipticCurvePrivateKey,
    *,
    rp_id: str = "localhost",
    origin: str = "http://localhost:8000",
    credential_id: bytes | None = None,
    backup_eligible: bool = True,
    backup_state: bool = True,
    user_verified: bool = True,
) -> dict[str, Any]:
    """Craft an L3-JSON registration credential signed with ``private_key``.

    The same self-attested ``fmt=none`` ECDSA P-256 shape a browser emits for
    attestation=none, keyed by the caller so the key pair survives for later
    assertions. ``tests/test_setup.py`` carries an equivalent inline builder;
    this one is key-parameterized because authentication must re-sign with the
    same private key.
    """
    if credential_id is None:
        credential_id = secrets.token_bytes(32)
    flags = _flags(
        attested=True,
        user_verified=user_verified,
        backup_eligible=backup_eligible,
        backup_state=backup_state,
    )
    rp_id_hash = hashlib.sha256(rp_id.encode()).digest()
    auth_data = (
        rp_id_hash
        + bytes([flags])
        + (0).to_bytes(4, "big")  # registration sign count
        + (b"\x00" * 16)  # AAGUID
        + len(credential_id).to_bytes(2, "big")
        + credential_id
        + _cose_public_key(private_key)
    )
    attestation_object = cbor2.dumps({"fmt": "none", "attStmt": {}, "authData": auth_data})
    client_data_json = json.dumps(
        {"type": "webauthn.create", "challenge": _b64url(challenge), "origin": origin}
    ).encode()
    return {
        "id": _b64url(credential_id),
        "rawId": _b64url(credential_id),
        "type": "public-key",
        "response": {
            "clientDataJSON": _b64url(client_data_json),
            "attestationObject": _b64url(attestation_object),
            "transports": ["internal"],
        },
    }


def build_authentication_response(
    challenge: bytes,
    private_key: ec.EllipticCurvePrivateKey,
    *,
    rp_id: str = "localhost",
    origin: str = "http://localhost:8000",
    credential_id: bytes,
    user_handle: bytes = b"\x01",
    user_verified: bool = True,
    sign_count: int = 1,
    backup_eligible: bool = True,
    backup_state: bool = True,
) -> dict[str, Any]:
    """Craft an L3-JSON assertion signed with ``private_key``.

    Authenticator data for a ``get()`` carries no attested credential data:
    rpIdHash + flags + sign count only. The signature covers
    ``authenticatorData || SHA-256(clientDataJSON)`` (ES256, DER-encoded).
    """
    flags = _flags(
        attested=False,
        user_verified=user_verified,
        backup_eligible=backup_eligible,
        backup_state=backup_state,
    )
    rp_id_hash = hashlib.sha256(rp_id.encode()).digest()
    auth_data = rp_id_hash + bytes([flags]) + sign_count.to_bytes(4, "big")
    client_data_json = json.dumps(
        {"type": "webauthn.get", "challenge": _b64url(challenge), "origin": origin}
    ).encode()
    client_data_hash = hashlib.sha256(client_data_json).digest()
    signature = private_key.sign(auth_data + client_data_hash, ec.ECDSA(hashes.SHA256()))
    return {
        "id": _b64url(credential_id),
        "rawId": _b64url(credential_id),
        "type": "public-key",
        "response": {
            "clientDataJSON": _b64url(client_data_json),
            "authenticatorData": _b64url(auth_data),
            "signature": _b64url(signature),
            "userHandle": _b64url(user_handle),
        },
    }

# The middleware's exemption list, re-derived here as the behavioural contract
# the route-scan test enforces (an independent copy on purpose: the scan must
# catch a wrong change to the middleware's list).
_EXEMPT_PREFIXES = ("/api/setup/", "/api/auth/", "/static")
_EXEMPT_EXACT_PATHS = frozenset({"/setup", "/health"})
_EXEMPT_METHOD_PATHS = frozenset({("POST", "/api/recovery/redeem")})


def _make_key() -> ec.EllipticCurvePrivateKey:
    return ec.generate_private_key(ec.SECP256R1())


def _register(
    client: TestClient,
    private_key: ec.EllipticCurvePrivateKey,
    *,
    credential_id: bytes,
    **kwargs: Any,
):
    """Run a full registration ceremony with a known key; returns the verify response."""
    options = client.post("/api/setup/options")
    assert options.status_code == 200, options.text
    challenge = _b64url_decode(options.json()["challenge"])
    credential = build_registration_response(
        challenge, private_key, credential_id=credential_id, **kwargs
    )
    resp = client.post("/api/setup/verify", json=credential)
    assert resp.status_code == 200, resp.text
    return resp


def _login(
    client: TestClient,
    private_key: ec.EllipticCurvePrivateKey,
    credential_id: bytes,
    **kwargs: Any,
):
    """Run the usernameless login ceremony; returns the verify response."""
    options = client.post("/api/auth/options")
    assert options.status_code == 200, options.text
    challenge = _b64url_decode(options.json()["challenge"])
    credential = build_authentication_response(
        challenge, private_key, credential_id=credential_id, **kwargs
    )
    return client.post("/api/auth/verify", json=credential)


# ---------------------------------------------------------------------------
# POST /api/auth/options — usernameless, UV=REQUIRED, challenge lifecycle
# ---------------------------------------------------------------------------


def test_auth_options_are_usernameless_and_uv_required(fresh_db):
    with TestClient(app) as client:
        resp = client.post("/api/auth/options")
    assert resp.status_code == 200
    body = resp.json()
    assert body["rpId"] == config.WEBAUTHN_RP_ID == "localhost"
    assert body["allowCredentials"] == []  # usernameless discoverable login
    assert body["userVerification"] == "required"
    assert body["timeout"] == 60000
    assert body["challenge"]


def test_auth_options_stores_authentication_challenge_with_ttl(fresh_db):
    with TestClient(app) as client:
        options = client.post("/api/auth/options").json()
    challenge = _b64url_decode(options["challenge"])
    row = db.get_conn().execute(
        "SELECT purpose, expires_at FROM webauthn_challenges WHERE challenge = ?",
        (challenge,),
    ).fetchone()
    assert row is not None
    assert row["purpose"] == "authentication"
    ttl = row["expires_at"] - int(time.time())
    assert 240 <= ttl <= 300


# ---------------------------------------------------------------------------
# POST /api/auth/verify — full ceremony, session + cookies
# ---------------------------------------------------------------------------


def test_full_login_creates_normal_session_and_sets_cookies(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _register(client, key, credential_id=cid)
        resp = _login(client, key, cid)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    session_row = db.get_conn().execute(
        "SELECT id, scope, csrf_token, expires_at FROM sessions WHERE id = ?",
        (body["session_id"],),
    ).fetchone()
    assert session_row is not None
    assert session_row["scope"] == "normal"
    assert session_row["expires_at"] > int(time.time())
    assert resp.cookies.get(auth.SESSION_COOKIE_NAME) == body["session_id"]
    assert resp.cookies.get("csrf_token") == session_row["csrf_token"]


def test_login_sets_session_cookie_flags(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _register(client, key, credential_id=cid)
        resp = _login(client, key, cid)
    set_cookies = resp.headers.get_list("set-cookie")
    assert len(set_cookies) == 2
    session_ck = set_cookies[0]
    csrf_ck = set_cookies[1]
    assert "session=" in session_ck
    assert "HttpOnly" in session_ck
    assert "SameSite=strict" in session_ck
    assert "Path=/" in session_ck
    assert "csrf_token=" in csrf_ck
    assert "HttpOnly" not in csrf_ck  # readable by the frontend JS
    if config.IS_PROD:
        assert "Secure" in session_ck
        assert "Secure" in csrf_ck


def test_login_sets_secure_cookie_when_prod_predicate_is_true(fresh_db, monkeypatch):
    """The Secure flag follows the prod predicate (todo 2): a non-loopback
    PUBLIC_ORIGIN turns it on, a loopback origin leaves it off."""
    monkeypatch.setattr(config, "IS_PROD", True)
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _register(client, key, credential_id=cid)
        resp = _login(client, key, cid)
    set_cookies = resp.headers.get_list("set-cookie")
    assert len(set_cookies) == 2
    assert all("Secure" in ck for ck in set_cookies)


def test_authenticated_requests_succeed_after_login(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _register(client, key, credential_id=cid)
        _login(client, key, cid)
        assert client.get("/api/search").status_code == 200
        assert client.get("/api/tags").status_code == 200
        resp = client.get("/")
        assert resp.status_code == 200
        assert "text/html" in resp.headers["content-type"]


# ---------------------------------------------------------------------------
# Rejections: unknown credential, single-use challenge, wrong rp/origin, body
# ---------------------------------------------------------------------------


def test_login_rejects_unknown_credential(fresh_db):
    key = _make_key()
    with TestClient(app) as client:
        options = client.post("/api/auth/options").json()
        credential = build_authentication_response(
            _b64url_decode(options["challenge"]), key, credential_id=secrets.token_bytes(32)
        )
        resp = client.post("/api/auth/verify", json=credential)
    assert resp.status_code == 400
    assert "unknown credential" in resp.json()["detail"]


def test_login_rejects_reused_challenge(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _register(client, key, credential_id=cid)
        options = client.post("/api/auth/options").json()
        challenge = _b64url_decode(options["challenge"])
        # A failed presentation (wrong origin) still consumes the challenge.
        bad = build_authentication_response(challenge, key, credential_id=cid, origin="http://evil.example")
        assert client.post("/api/auth/verify", json=bad).status_code == 400
        good = build_authentication_response(challenge, key, credential_id=cid)
        resp = client.post("/api/auth/verify", json=good)
    assert resp.status_code == 400  # stale — single-use challenges never repeat


def test_login_rejects_response_for_wrong_rp_id(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _register(client, key, credential_id=cid)
        options = client.post("/api/auth/options").json()
        credential = build_authentication_response(
            _b64url_decode(options["challenge"]), key, credential_id=cid, rp_id="example.com"
        )
        resp = client.post("/api/auth/verify", json=credential)
    assert resp.status_code == 400


def test_login_rejects_response_for_wrong_origin(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _register(client, key, credential_id=cid)
        options = client.post("/api/auth/options").json()
        credential = build_authentication_response(
            _b64url_decode(options["challenge"]),
            key,
            credential_id=cid,
            origin="https://evil.example",
        )
        resp = client.post("/api/auth/verify", json=credential)
    assert resp.status_code == 400


def test_login_rejects_malformed_body(fresh_db):
    with TestClient(app) as client:
        resp = client.post(
            "/api/auth/verify",
            content="this is not an assertion",
            headers={"Content-Type": "application/json"},
        )
    assert resp.status_code == 400


# ---------------------------------------------------------------------------
# BE-gated, lenient sign-count policy (w3c #2172 caveat)
# ---------------------------------------------------------------------------


def test_login_updates_sign_count_for_single_device_credential(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _register(client, key, credential_id=cid, backup_eligible=False, backup_state=False)
        resp = _login(
            client, key, cid, sign_count=7, backup_eligible=False, backup_state=False
        )
        assert resp.status_code == 200, resp.text
    row = db.get_conn().execute(
        "SELECT sign_count FROM passkey_credentials WHERE credential_id = ?", (cid,)
    ).fetchone()
    assert row["sign_count"] == 7


def test_login_backup_eligible_never_hard_fails_on_stale_counter(fresh_db):
    """Synced passkeys (BE=1) can report stale or racing counters; the login
    must succeed and the new counter is accepted leniently."""
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _register(client, key, credential_id=cid)  # BE=1 by default
        assert _login(client, key, cid, sign_count=5).status_code == 200
        resp = _login(client, key, cid, sign_count=2)  # counter went backwards
        assert resp.status_code == 200, resp.text
    row = db.get_conn().execute(
        "SELECT sign_count FROM passkey_credentials WHERE credential_id = ?", (cid,)
    ).fetchone()
    assert row["sign_count"] == 2


def test_login_stored_zero_counter_never_hard_fails(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _register(client, key, credential_id=cid, backup_eligible=False, backup_state=False)
        resp = _login(
            client, key, cid, sign_count=0, backup_eligible=False, backup_state=False
        )
        assert resp.status_code == 200, resp.text
    row = db.get_conn().execute(
        "SELECT sign_count FROM passkey_credentials WHERE credential_id = ?", (cid,)
    ).fetchone()
    assert row["sign_count"] == 0


def test_login_single_device_regression_does_not_lock_account(fresh_db):
    """BE=0 with a stored counter: the usual monotonic check applies, but a
    regression does NOT lock the account — the login succeeds and the stored
    counter is left untouched."""
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _register(client, key, credential_id=cid, backup_eligible=False, backup_state=False)
        assert (
            _login(client, key, cid, sign_count=5, backup_eligible=False, backup_state=False)
            .status_code
            == 200
        )
        resp = _login(client, key, cid, sign_count=4, backup_eligible=False, backup_state=False)
        assert resp.status_code == 200, resp.text
    row = db.get_conn().execute(
        "SELECT sign_count FROM passkey_credentials WHERE credential_id = ?", (cid,)
    ).fetchone()
    assert row["sign_count"] == 5  # regressed value is not persisted


# ---------------------------------------------------------------------------
# Unauthenticated matrix: 401 JSON for API, 401-with-login-page for HTML
# ---------------------------------------------------------------------------


def test_unauthenticated_api_returns_401(fresh_db):
    with TestClient(app) as client:
        matrix = [
            ("GET", "/"),
            ("GET", "/api/search"),
            ("POST", "/api/bookmarks"),
            ("DELETE", "/api/bookmarks/1"),
            ("POST", "/api/import"),
            ("GET", "/api/tags"),
            ("POST", "/api/recovery/regenerate"),  # NOT exempt — only redeem is
        ]
        for method, path in matrix:
            resp = client.request(method, path)
            assert resp.status_code == 401, f"{method} {path} -> {resp.status_code}"
            assert resp.json() == {"detail": "Not authenticated"}


def test_unauthenticated_html_request_gets_login_page(fresh_db):
    with TestClient(app) as client:
        resp = client.get("/", headers={"Accept": "text/html"})
    assert resp.status_code == 401
    assert "text/html" in resp.headers["content-type"]
    body = resp.text
    assert "navigator.credentials.get" in body
    assert "/api/auth/options" in body
    assert "/api/auth/verify" in body
    assert 'href="/setup"' in body  # the setup link (shown only when possible)


def test_exempt_routes_reachable_without_session(fresh_db):
    with TestClient(app) as client:
        assert client.get("/setup").status_code == 200
        assert client.post("/api/setup/options").status_code == 200
        assert client.get("/health").status_code == 200
        # POST /api/recovery/redeem is the ONLY /api/recovery/* route exempt
        # from auth: it must never 401. Its handler landed in todo 11, so an
        # unauthenticated call with an unknown code is a 400 — never 401.
        resp = client.post("/api/recovery/redeem", json={"code": "whatever"})
        assert resp.status_code == 400
        assert resp.status_code != 401


# ---------------------------------------------------------------------------
# CSRF: mutating writes echo X-CSRF-Token matching the session
# ---------------------------------------------------------------------------


def test_csrf_missing_on_write_rejected(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _register(client, key, credential_id=cid)
        _login(client, key, cid)
        resp = client.post("/api/bookmarks", data={"url": "https://example.com"})
    assert resp.status_code == 403
    assert resp.json() == {"detail": "CSRF token mismatch"}


def test_csrf_wrong_token_on_write_rejected(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _register(client, key, credential_id=cid)
        _login(client, key, cid)
        resp = client.post(
            "/api/bookmarks",
            data={"url": "https://example.com"},
            headers={"X-CSRF-Token": "wrong-token"},
        )
    assert resp.status_code == 403


def test_csrf_valid_token_on_write_succeeds(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _register(client, key, credential_id=cid)
        _login(client, key, cid)
        token = client.cookies.get("csrf_token")
        assert token
        resp = client.post(
            "/api/bookmarks",
            data={"url": "https://example.com"},
            headers={"X-CSRF-Token": token},
        )
    assert resp.status_code == 200
    assert "id" in resp.json()


# ---------------------------------------------------------------------------
# Stale / expired / unknown sessions
# ---------------------------------------------------------------------------


def test_expired_session_rejected(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _register(client, key, credential_id=cid)
        _login(client, key, cid)
        session_id = client.cookies.get(auth.SESSION_COOKIE_NAME)
        with db.transaction() as conn:
            conn.execute(
                "UPDATE sessions SET expires_at = ? WHERE id = ?",
                (int(time.time()) - 10, session_id),
            )
        resp = client.get("/api/search")
    assert resp.status_code == 401


def test_unknown_session_cookie_rejected(fresh_db):
    with TestClient(app) as client:
        client.cookies.set(auth.SESSION_COOKIE_NAME, "not-a-real-session")
        resp = client.get("/api/search")
    assert resp.status_code == 401


# ---------------------------------------------------------------------------
# Recovery-scoped sessions: pinned to /api/setup/*, GET /setup, POST redeem
# ---------------------------------------------------------------------------


def test_recovery_scoped_session_rejected_on_normal_routes(fresh_db):
    with TestClient(app) as client:
        sid = auth.create_session(scope="recovery")
        client.cookies.set(auth.SESSION_COOKIE_NAME, sid)
        assert client.get("/api/search").status_code == 403
        assert (
            client.post("/api/bookmarks", data={"url": "https://x.com"}).status_code == 403
        )
        # /api/auth/* is off-limits to a recovery session too: it must never
        # be able to mint a normal session or reach account surfaces.
        assert client.post("/api/auth/options").status_code == 403
    auth.logout(sid)


def test_recovery_scoped_session_allowed_on_setup_and_redeem(fresh_db):
    with TestClient(app) as client:
        sid = auth.create_session(scope="recovery")
        client.cookies.set(auth.SESSION_COOKIE_NAME, sid)
        assert client.get("/setup").status_code == 200
        assert client.post("/api/setup/options").status_code == 200
        redeem = client.post("/api/recovery/redeem", json={"code": "whatever"})
        assert redeem.status_code != 403
    auth.logout(sid)


# ---------------------------------------------------------------------------
# Logout
# ---------------------------------------------------------------------------


def test_logout_deletes_session_and_clears_cookies(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _register(client, key, credential_id=cid)
        _login(client, key, cid)
        session_id = client.cookies.get(auth.SESSION_COOKIE_NAME)
        resp = client.post("/api/auth/logout")
        assert resp.status_code == 200
        assert (
            db.get_conn()
            .execute("SELECT COUNT(*) AS n FROM sessions WHERE id = ?", (session_id,))
            .fetchone()["n"]
            == 0
        )
        # The stale cookie no longer authenticates anything.
        assert client.get("/api/search").status_code == 401


# ---------------------------------------------------------------------------
# Route-scan: every registered route is exempt-listed or requires auth
# ---------------------------------------------------------------------------


def test_route_scan_every_route_requires_auth_except_exemption_list(fresh_db):
    """Walk every registered route (app.routes) and assert each one except the
    exemption list returns 401 without a session. This is the load-bearing
    guarantee for routes added in later waves (todos 15,17,18,23,...): the
    global middleware protects them by default, and this scan catches any
    accidentally-public route.

    Auto-added routes: the app ships with docs_url/redoc_url disabled, so the
    only FastAPI-generated route is GET/HEAD /openapi.json. It is NOT in the
    exemption list and must 401 unauthenticated (the schema stays behind auth;
    with no docs UI there is no dev-only reason to leave it open).
    """

    def substitute_params(path: str) -> str:
        return re.sub(r"\{[^}]+\}", "1", path)

    with TestClient(app) as client:
        for route in app.routes:
            path = getattr(route, "path", None)
            methods = getattr(route, "methods", None)
            if methods is None:
                # A mount (e.g. /static) has no methods; it must sit under an
                # exempt prefix so its files stay reachable.
                assert path is not None and path.startswith(
                    _EXEMPT_PREFIXES
                ), f"mount {path} is not under an exempt prefix"
                continue
            assert path is not None  # routes carrying methods always have a path
            for method in sorted(methods):
                target = substitute_params(path)
                exempt = (
                    target in _EXEMPT_EXACT_PATHS
                    or target.startswith(_EXEMPT_PREFIXES)
                    or (method, target) in _EXEMPT_METHOD_PATHS
                )
                resp = client.request(method, target)
                if exempt:
                    assert resp.status_code != 401, f"{method} {target} should be exempt"
                else:
                    assert resp.status_code == 401, f"{method} {target} is unprotected"
