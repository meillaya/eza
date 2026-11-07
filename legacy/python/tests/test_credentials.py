"""Credential management + session TTL + recovery-code regeneration (todo 12).

API-level tests for GET /api/credentials, PATCH /api/credentials/{id},
DELETE /api/credentials/{id}, POST /api/recovery/regenerate and the /account
page. The dual-passkey browser ceremonies (register a 2nd credential, login
with each) are deferred to todo 13's Playwright harness; here a second
credential is seeded by direct insert because the setup flow only ever enrolls
one credential once ``setup_claimed`` is set.

Scenarios pinned:

- happy: rename a secondary credential via PATCH, delete it via DELETE, list
  reflects both changes.
- happy: regenerate via POST /api/recovery/regenerate (authed + CSRF header)
  returns 10 new codes and the OLD code hash no longer redeems (a previously
  issued plaintext code -> 400).
- failure: DELETE the LAST credential -> 400 with a recovery-path hint, row
  survives.
- unauth: POST /api/recovery/regenerate -> 401 without a session (regenerate
  is NOT exempt — only POST /api/recovery/redeem is).
- TTL: an expired session row is rejected with 401 on authed routes.
- /account page: 200 authed, 401-with-login-page unauth.
"""

from __future__ import annotations

import hashlib
import secrets
import time

from fastapi.testclient import TestClient

from app import auth, db
from app.main import app
from tests.test_auth import _b64url, _login, _make_key, _register


def _insert_credential(
    credential_id: bytes,
    *,
    nickname: str = "",
    backup_eligible: int = 1,
    created_at: int | None = None,
) -> None:
    """Seed an extra passkey row directly (the setup flow only enrolls one)."""
    now = int(time.time()) if created_at is None else created_at
    with db.transaction() as conn:
        conn.execute(
            """
            INSERT INTO passkey_credentials (
                credential_id, public_key, cose_alg, sign_count, aaguid,
                transports, backup_eligible, backup_state, user_handle,
                nickname, created_at, last_used_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                credential_id,
                b"\x00",
                -7,
                0,
                b"\x00" * 16,
                "[]",
                backup_eligible,
                0,
                auth.USER_HANDLE,
                nickname,
                now,
                now,
            ),
        )


def _setup_and_login(client: TestClient, key, cid: bytes) -> dict:
    """Register the first passkey, then log in — returns the login response."""
    _register(client, key, credential_id=cid)
    resp = _login(client, key, cid)
    assert resp.status_code == 200, resp.text
    return resp


# ---------------------------------------------------------------------------
# Happy path: rename + delete a secondary credential, list reflects changes
# ---------------------------------------------------------------------------


def test_list_credentials_exposes_management_fields(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _setup_and_login(client, key, cid)
        listing = client.get("/api/credentials").json()["credentials"]
    assert len(listing) == 1
    cred = listing[0]
    assert cred["id"] == _b64url(cid)
    assert cred["nickname"] == ""
    assert isinstance(cred["created_at"], int)
    assert cred["backup_eligible"] is True
    assert isinstance(cred["last_used_at"], int)  # set at registration


def test_rename_secondary_credential_updates_listing(fresh_db):
    key = _make_key()
    cid1 = secrets.token_bytes(32)
    cid2 = secrets.token_bytes(32)
    with TestClient(app) as client:
        _setup_and_login(client, key, cid1)
        _insert_credential(cid2, nickname="Work laptop")
        token = client.cookies.get("csrf_token")
        assert token
        resp = client.patch(
            f"/api/credentials/{_b64url(cid2)}",
            json={"nickname": "Desktop"},
            headers={"X-CSRF-Token": token},
        )
        assert resp.status_code == 200, resp.text
        listing = client.get("/api/credentials").json()["credentials"]
    by_id = {c["id"]: c for c in listing}
    assert by_id[_b64url(cid2)]["nickname"] == "Desktop"
    assert by_id[_b64url(cid1)]["nickname"] == ""  # untouched


def test_delete_secondary_credential_reflects_in_listing(fresh_db):
    key = _make_key()
    cid1 = secrets.token_bytes(32)
    cid2 = secrets.token_bytes(32)
    with TestClient(app) as client:
        _setup_and_login(client, key, cid1)
        _insert_credential(cid2, nickname="Work laptop")
        token = client.cookies.get("csrf_token")
        resp = client.delete(
            f"/api/credentials/{_b64url(cid2)}",
            headers={"X-CSRF-Token": token},
        )
        assert resp.status_code == 200, resp.text
        listing = client.get("/api/credentials").json()["credentials"]
    assert [c["id"] for c in listing] == [_b64url(cid1)]


# ---------------------------------------------------------------------------
# Failure: rename/delete an unknown credential -> 404, bad nickname -> 400
# ---------------------------------------------------------------------------


def test_rename_and_delete_unknown_credential_return_404(fresh_db):
    key = _make_key()
    cid1 = secrets.token_bytes(32)
    cid2 = secrets.token_bytes(32)
    with TestClient(app) as client:
        _setup_and_login(client, key, cid1)
        _insert_credential(cid2)  # a second credential, so the last-credential
        # guard cannot shadow the not-found case on DELETE
        token = client.cookies.get("csrf_token")
        bogus = _b64url(secrets.token_bytes(32))
        rename = client.patch(
            f"/api/credentials/{bogus}",
            json={"nickname": "nope"},
            headers={"X-CSRF-Token": token},
        )
        assert rename.status_code == 404
        delete = client.delete(
            f"/api/credentials/{bogus}",
            headers={"X-CSRF-Token": token},
        )
        assert delete.status_code == 404


def test_rename_rejects_non_string_nickname(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _setup_and_login(client, key, cid)
        token = client.cookies.get("csrf_token")
        resp = client.patch(
            f"/api/credentials/{_b64url(cid)}",
            json={"nickname": 42},
            headers={"X-CSRF-Token": token},
        )
    assert resp.status_code == 400


# ---------------------------------------------------------------------------
# Last-credential guard: DELETE is blocked with a recovery-path hint
# ---------------------------------------------------------------------------


def test_delete_last_credential_blocked_with_recovery_hint(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _setup_and_login(client, key, cid)
        token = client.cookies.get("csrf_token")
        resp = client.delete(
            f"/api/credentials/{_b64url(cid)}",
            headers={"X-CSRF-Token": token},
        )
        assert resp.status_code == 400
        assert "recovery" in resp.json()["detail"].lower()
    assert auth.count_credentials() == 1  # the row survives the blocked delete


# ---------------------------------------------------------------------------
# Regeneration: rotation — old hashes die, 10 new codes are returned once
# ---------------------------------------------------------------------------


def test_regenerate_rotates_codes_and_invalidates_old(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        setup_resp = _register(client, key, credential_id=cid)
        old_codes = setup_resp.json()["codes"]
        assert _login(client, key, cid).status_code == 200
        token = client.cookies.get("csrf_token")
        resp = client.post("/api/recovery/regenerate", headers={"X-CSRF-Token": token})
        assert resp.status_code == 200, resp.text
        new_codes = resp.json()["codes"]
        assert len(new_codes) == 10
        assert len(set(new_codes)) == 10
        assert not (set(new_codes) & set(old_codes))  # genuinely new codes

        stored = {
            row["code_hash"]
            for row in db.get_conn().execute("SELECT code_hash FROM recovery_codes")
        }
        assert len(stored) == 10
        for code in new_codes:
            assert hashlib.sha256(code.encode()).hexdigest() in stored

        # Rotation: the pre-regeneration hash is gone AND no longer redeems.
        old_hash = hashlib.sha256(old_codes[0].encode()).hexdigest()
        assert (
            db.get_conn()
            .execute(
                "SELECT COUNT(*) AS n FROM recovery_codes WHERE code_hash = ?",
                (old_hash,),
            )
            .fetchone()["n"]
            == 0
        )
        redeem_old = client.post("/api/recovery/redeem", json={"code": old_codes[0]})
        assert redeem_old.status_code == 400

        # The fresh batch is live: a new code still redeems.
        redeem_new = client.post("/api/recovery/redeem", json={"code": new_codes[0]})
        assert redeem_new.status_code == 200


def test_regenerate_requires_csrf_token(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _setup_and_login(client, key, cid)
        resp = client.post("/api/recovery/regenerate")
    assert resp.status_code == 403
    assert resp.json() == {"detail": "CSRF token mismatch"}


# ---------------------------------------------------------------------------
# Unauthenticated: regenerate -> 401, the /account page -> 401 login page
# ---------------------------------------------------------------------------


def test_regenerate_requires_auth(fresh_db):
    with TestClient(app) as client:
        resp = client.post("/api/recovery/regenerate")
    assert resp.status_code == 401
    assert resp.json() == {"detail": "Not authenticated"}


def test_account_page_requires_auth(fresh_db):
    with TestClient(app) as client:
        resp = client.get("/account", headers={"Accept": "text/html"})
    assert resp.status_code == 401
    assert "text/html" in resp.headers["content-type"]
    assert "navigator.credentials.get" in resp.text  # the login page body


def test_account_page_loads_when_authed(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _setup_and_login(client, key, cid)
        resp = client.get("/account")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    assert "/api/credentials" in resp.text
    assert "/api/recovery/regenerate" in resp.text


# ---------------------------------------------------------------------------
# Session TTL (todo 2 config): an expired session row is rejected on authed
# routes — the credentials API and the /account page both 401.
# ---------------------------------------------------------------------------


def test_expired_session_rejected_on_authed_routes(fresh_db):
    key = _make_key()
    cid = secrets.token_bytes(32)
    with TestClient(app) as client:
        _setup_and_login(client, key, cid)
        session_id = client.cookies.get(auth.SESSION_COOKIE_NAME)
        with db.transaction() as conn:
            conn.execute(
                "UPDATE sessions SET expires_at = ? WHERE id = ?",
                (int(time.time()) - 10, session_id),
            )
        assert client.get("/api/credentials").status_code == 401
        assert client.get("/account", headers={"Accept": "text/html"}).status_code == 401
