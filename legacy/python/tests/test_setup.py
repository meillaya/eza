"""Tests for the first-run /setup bootstrap (todo 9).

The browser ceremony itself is deferred to todo 13's Playwright harness; these
tests exercise the full API shape at TestClient level. Registration responses
are crafted in-process against the challenge the options endpoint returns
(a self-attested "none" ECDSA P-256 response, exactly what a browser's
``navigator.credentials.create().toJSON()`` produces for attestation=none), so
``verify_registration_response`` is genuinely exercised end-to-end.

The tests pin the server-side setup guard (403 when credentials exist unless a
valid recovery-scoped session is present), the challenge lifecycle (single-use,
5-minute TTL, stale/expired rejected), the ``setup_claimed`` marker, the 10
one-time recovery codes shown once on the setup-complete screen, and the
post-recovery race closure (claimed + revoked credentials + no scoped session
must not be anonymously re-claimable).
"""

from __future__ import annotations

import hashlib
import json
import secrets
import time
from base64 import urlsafe_b64decode, urlsafe_b64encode

import cbor2
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from app import auth, config, db
from app.main import app


def _b64url(data: bytes) -> str:
    return urlsafe_b64encode(data).rstrip(b"=").decode()


def _b64url_decode(data: str) -> bytes:
    return urlsafe_b64decode(data + "=" * (-len(data) % 4))


def build_registration_response(
    challenge: bytes,
    *,
    rp_id: str = "localhost",
    origin: str = "http://localhost:8000",
    credential_id: bytes | None = None,
    backup_eligible: bool = True,
    backup_state: bool = True,
    user_verified: bool = True,
) -> dict:
    """Craft an L3-JSON registration credential for a given challenge.

    Composes the authenticator data (rpIdHash + flags + sign count + attested
    credential data with an ECDSA P-256 COSE public key) and the ``fmt=none``
    attestation object the same way a browser would after a registration
    ceremony. With attestation=none there is no attestation signature to check,
    so the response is fully valid for ``verify_registration_response``.
    """
    if credential_id is None:
        credential_id = secrets.token_bytes(32)
    private_key = ec.generate_private_key(ec.SECP256R1())
    public_numbers = private_key.public_key().public_numbers()
    x = public_numbers.x.to_bytes(32, "big")
    y = public_numbers.y.to_bytes(32, "big")
    cose_public_key = cbor2.dumps({1: 2, 3: -7, -1: 1, -2: x, -3: y})

    flags = 0x41  # UP + AT
    if user_verified:
        flags |= 0x04  # UV
    if backup_eligible:
        flags |= 0x08  # BE
    if backup_state:
        flags |= 0x10  # BS

    rp_id_hash = hashlib.sha256(rp_id.encode()).digest()
    auth_data = (
        rp_id_hash
        + bytes([flags])
        + (0).to_bytes(4, "big")
        + (b"\x00" * 16)  # AAGUID
        + len(credential_id).to_bytes(2, "big")
        + credential_id
        + cose_public_key
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


def _options(client: TestClient) -> dict:
    resp = client.post("/api/setup/options")
    assert resp.status_code == 200
    return resp.json()


def _verify(client: TestClient, credential: dict):
    return client.post("/api/setup/verify", json=credential)


def register_passkey(client: TestClient, **kwargs):
    """Run a full registration ceremony through the API; returns the verify response."""
    options = _options(client)
    challenge = _b64url_decode(options["challenge"])
    credential = build_registration_response(challenge, **kwargs)
    return _verify(client, credential)


# ---------------------------------------------------------------------------
# Registration options shape (rp.id from config, never 127.0.0.1)
# ---------------------------------------------------------------------------


def test_setup_options_uses_localhost_rp_id_and_required_selection(fresh_db):
    """Options built against the DEFAULT config carry rp.id == "localhost".

    A raw IP like 127.0.0.1 is rejected by browsers as an RP ID for
    registration, so the loopback default must resolve to "localhost".
    """
    with TestClient(app) as client:
        options = _options(client)
    assert options["rp"]["id"] == "localhost"
    assert options["rp"]["name"] == config.WEBAUTHN_RP_NAME
    assert options["attestation"] == "none"
    selection = options["authenticatorSelection"]
    assert selection["residentKey"] == "required"
    assert selection["userVerification"] == "required"
    assert options["user"]["id"] == _b64url(auth.USER_HANDLE)


def test_setup_options_stores_challenge_with_purpose_and_ttl(fresh_db):
    """The challenge is persisted with purpose='registration' and a 5-minute TTL."""
    with TestClient(app) as client:
        options = _options(client)
    challenge = _b64url_decode(options["challenge"])
    conn = db.get_conn()
    row = conn.execute(
        "SELECT purpose, expires_at FROM webauthn_challenges WHERE challenge = ?",
        (challenge,),
    ).fetchone()
    assert row is not None
    assert row["purpose"] == "registration"
    ttl = row["expires_at"] - int(time.time())
    assert 240 <= ttl <= 300


# ---------------------------------------------------------------------------
# GET /setup
# ---------------------------------------------------------------------------


def test_get_setup_serves_page_when_no_credentials(fresh_db):
    with TestClient(app) as client:
        resp = client.get("/setup")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]


def test_get_setup_returns_404_after_registration(fresh_db):
    with TestClient(app) as client:
        register_passkey(client)
        resp = client.get("/setup")
    assert resp.status_code == 404


# ---------------------------------------------------------------------------
# Full ceremony: credential + session persistence, codes, claimed marker
# ---------------------------------------------------------------------------


def test_full_registration_stores_credential_be_bs_transports(fresh_db):
    with TestClient(app) as client:
        resp = register_passkey(client)
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"
    row = db.get_conn().execute("SELECT * FROM passkey_credentials").fetchone()
    assert row is not None
    assert row["cose_alg"] == -7
    assert row["backup_eligible"] == 1  # BE
    assert row["backup_state"] == 1  # BS
    assert json.loads(row["transports"]) == ["internal"]
    assert row["user_handle"] == auth.USER_HANDLE
    assert row["sign_count"] == 0


def test_full_registration_creates_normal_session_and_sets_cookie(fresh_db):
    with TestClient(app) as client:
        resp = register_passkey(client)
    assert resp.status_code == 200
    body = resp.json()
    session_row = db.get_conn().execute(
        "SELECT id, scope, expires_at FROM sessions WHERE id = ?", (body["session_id"],)
    ).fetchone()
    assert session_row is not None
    assert session_row["scope"] == "normal"
    assert session_row["expires_at"] > int(time.time())
    cookie = resp.cookies.get(auth.SESSION_COOKIE_NAME)
    assert cookie == body["session_id"]


def test_setup_claimed_marker_set_after_registration(fresh_db):
    with TestClient(app) as client:
        register_passkey(client)
    row = db.get_conn().execute("SELECT setup_claimed FROM users WHERE id = 1").fetchone()
    assert row["setup_claimed"] == 1


def test_setup_complete_returns_ten_one_time_codes(fresh_db):
    """The setup-complete response carries exactly 10 distinct codes; only their
    SHA-256 hashes are persisted — never the plaintext."""
    with TestClient(app) as client:
        resp = register_passkey(client)
    assert resp.status_code == 200
    codes = resp.json()["codes"]
    assert len(codes) == 10
    assert len(set(codes)) == 10
    stored = {
        row["code_hash"] for row in db.get_conn().execute("SELECT code_hash FROM recovery_codes")
    }
    assert len(stored) == 10
    for code in codes:
        assert hashlib.sha256(code.encode()).hexdigest() in stored
    assert not (set(codes) & stored)  # plaintext codes never touch the DB


# ---------------------------------------------------------------------------
# Server-side setup guard (enforced in the endpoint, no middleware yet)
# ---------------------------------------------------------------------------


def test_setup_options_403_when_credential_exists(fresh_db):
    with TestClient(app) as client:
        register_passkey(client)
        resp = client.post("/api/setup/options")
    assert resp.status_code == 403


def test_setup_verify_403_when_credential_exists(fresh_db):
    with TestClient(app) as client:
        options = _options(client)
        challenge = _b64url_decode(options["challenge"])
        credential = build_registration_response(challenge)
        register_passkey(client)
        resp = _verify(client, credential)
    assert resp.status_code == 403


def test_setup_verify_403_when_claimed_but_no_recovery_session(fresh_db):
    """Post-recovery race closure: credentials revoked + setup claimed + no valid
    recovery-scoped session must NOT be anonymously re-claimable."""
    with TestClient(app) as client:
        register_passkey(client)
        with db.transaction() as conn:
            conn.execute("DELETE FROM passkey_credentials")
        options = _options(client)  # options stay open: no credentials exist
        challenge = _b64url_decode(options["challenge"])
        credential = build_registration_response(challenge)
        resp = _verify(client, credential)
    assert resp.status_code == 403


def test_recovery_session_permits_resetup_after_revocation(fresh_db):
    """A valid recovery-scoped session re-opens registration once every
    credential has been revoked (the recovery flow's re-enrollment path)."""
    with TestClient(app) as client:
        register_passkey(client)
        with db.transaction() as conn:
            conn.execute("DELETE FROM passkey_credentials")
        auth.create_session(scope="recovery")
        resp = register_passkey(client)
    assert resp.status_code == 200
    assert len(resp.json()["codes"]) == 10


def test_expired_recovery_session_does_not_allow_resetup(fresh_db):
    """An expired recovery-scoped session is not a valid re-enrollment session."""
    with TestClient(app) as client:
        register_passkey(client)
        with db.transaction() as conn:
            conn.execute("DELETE FROM passkey_credentials")
        with db.transaction() as conn:
            conn.execute(
                "INSERT INTO sessions (id, csrf_token, scope, created_at, expires_at) "
                "VALUES (?, ?, 'recovery', ?, ?)",
                ("expired-recovery", "tok", int(time.time()), int(time.time()) - 1),
            )
        options = _options(client)
        challenge = _b64url_decode(options["challenge"])
        credential = build_registration_response(challenge)
        resp = _verify(client, credential)
    assert resp.status_code == 403


# ---------------------------------------------------------------------------
# Challenge lifecycle: single-use, stale/expired rejected
# ---------------------------------------------------------------------------


def test_stale_reused_challenge_is_rejected(fresh_db):
    """A challenge is single-use: any presentation consumes it, so reusing the
    same challenge bytes fails even with a valid credential."""
    with TestClient(app) as client:
        options = _options(client)
        challenge = _b64url_decode(options["challenge"])
        rejected = build_registration_response(challenge, origin="http://evil.example")
        assert _verify(client, rejected).status_code == 400  # consumed the challenge
        valid = build_registration_response(challenge)
        resp = _verify(client, valid)
    assert resp.status_code == 400  # stale challenge, not accepted a second time


def test_expired_challenge_is_rejected(fresh_db):
    challenge = secrets.token_bytes(32)
    with db.transaction() as conn:
        conn.execute(
            "INSERT INTO webauthn_challenges (challenge, purpose, expires_at) "
            "VALUES (?, 'registration', ?)",
            (challenge, int(time.time()) - 1),
        )
    credential = build_registration_response(challenge)
    with TestClient(app) as client:
        resp = _verify(client, credential)
    assert resp.status_code == 400


def test_verify_rejects_unknown_challenge(fresh_db):
    """A registration response whose challenge was never issued is rejected."""
    credential = build_registration_response(secrets.token_bytes(32))
    with TestClient(app) as client:
        resp = _verify(client, credential)
    assert resp.status_code == 400


def test_verify_rejects_response_for_wrong_rp_id(fresh_db):
    """The authenticator data's rpIdHash must match the configured RP ID."""
    with TestClient(app) as client:
        options = _options(client)
        challenge = _b64url_decode(options["challenge"])
        credential = build_registration_response(challenge, rp_id="example.com")
        resp = _verify(client, credential)
    assert resp.status_code == 400


def test_verify_rejects_malformed_body(fresh_db):
    with TestClient(app) as client:
        resp = client.post(
            "/api/setup/verify",
            content="this is not a credential",
            headers={"Content-Type": "application/json"},
        )
    assert resp.status_code == 400


# ---------------------------------------------------------------------------
# issue_codes() — the single shared code generator (todos 11/12 reuse it)
# ---------------------------------------------------------------------------


def test_issue_codes_generates_ten_codes_and_stores_hashes_only(fresh_db):
    codes = auth.issue_codes()
    assert len(codes) == 10
    assert len(set(codes)) == 10
    assert all(isinstance(code, str) and code for code in codes)
    rows = db.get_conn().execute(
        "SELECT code_hash, used, redeemed_at FROM recovery_codes"
    ).fetchall()
    assert len(rows) == 10
    stored = {row["code_hash"] for row in rows}
    for code in codes:
        assert hashlib.sha256(code.encode()).hexdigest() in stored
    assert all(row["used"] == 0 and row["redeemed_at"] is None for row in rows)
    assert not (set(codes) & stored)  # plaintext never stored


def test_issue_codes_appends_without_erasing_existing(fresh_db):
    """issue_codes() is additive: a second call stores a second batch."""
    first = auth.issue_codes()
    second = auth.issue_codes()
    assert len(second) == 10
    total = db.get_conn().execute("SELECT COUNT(*) AS n FROM recovery_codes").fetchone()["n"]
    assert total == 20
    assert not (set(first) & set(second))
