"""Recovery-code redemption, scoped re-enrollment and the reset escape hatch (todo 11).

The browser re-enrollment ceremony itself is deferred to todo 13's Playwright
harness; these tests exercise the redeem flow at TestClient level:

- POST /api/recovery/redeem: the ONLY /api/recovery/* route exempt from auth.
  A valid unused code creates a recovery-scoped session (10-min TTL) FIRST,
  then revokes ALL credentials + normal-scope sessions, then marks the code
  used. HTML Accept -> 303 to /setup; API -> 200 ``{"next": "/setup"}``.
  Unknown/used code -> 400.
- The scoped session may touch GET /setup and POST /api/setup/* ONLY: bookmark
  routes and /api/recovery/* (regenerate included) are 403 — the middleware
  fires before routing, so even not-yet-registered /api/recovery/* paths get
  403, never 404. HTML-Accept recovery-403s render a page with the /setup link.
- An expired scoped session grants nothing (401 on protected routes) and the
  post-recovery race closure holds (verify -> 403 once the session lapses).
- A failed re-registration consumes no extra state: exactly one code is used,
  credentials stay revoked, the scoped session stays usable, and a correct
  retry still succeeds.
- The ``bookmarks-reset-auth`` CLI returns the app to first-run state:
  credentials/sessions/codes emptied, setup_claimed cleared, GET /setup 200
  and POST /api/setup/verify working again.
"""

from __future__ import annotations

import hashlib
import time

from fastapi.testclient import TestClient

from app import auth, db
from app.main import app
from tests.test_setup import _b64url_decode, build_registration_response, register_passkey


def _redeem(client: TestClient, code: str, **kwargs):
    return client.post("/api/recovery/redeem", json={"code": code}, **kwargs)


def _first_setup(codes: list[str]) -> None:
    """Register the initial passkey and capture the 10 one-time codes."""
    with TestClient(app) as client:
        resp = register_passkey(client)
        assert resp.status_code == 200
        codes[:] = resp.json()["codes"]


# ---------------------------------------------------------------------------
# Happy path: redeem -> scoped session first -> re-register a new passkey
# ---------------------------------------------------------------------------


def test_redeem_creates_scoped_session_and_revokes_everything_then_reenrolls(fresh_db):
    """The full recovery ceremony at API level.

    Ordering is load-bearing: the scoped session is created BEFORE the
    revocation and excluded from it, so after a redeem exactly one
    recovery-scoped session exists, every credential and normal session is
    gone, and the code is marked used. The scoped session reaches only
    /setup + /api/setup/*, never bookmarks and never /api/recovery/*.
    """
    with TestClient(app) as client:
        # Initial registration issues the 10 codes.
        first_resp = register_passkey(client)
        codes = first_resp.json()["codes"]
        assert auth.count_credentials() == 1

        # Redeem one code: JSON API path -> {"next": "/setup"} + scoped cookie.
        redeem = _redeem(client, codes[0])
        assert redeem.status_code == 200, redeem.text
        assert redeem.json() == {"next": "/setup"}

        scoped_sid = client.cookies.get(auth.SESSION_COOKIE_NAME)
        assert scoped_sid is not None

        # Scoped session created FIRST and surviving: it is the only session.
        rows = db.get_conn().execute(
            "SELECT id, scope, expires_at FROM sessions"
        ).fetchall()
        assert len(rows) == 1
        assert rows[0]["id"] == scoped_sid
        assert rows[0]["scope"] == "recovery"
        ttl = rows[0]["expires_at"] - int(time.time())
        assert 9 * 60 <= ttl <= 10 * 60

        # Then credentials revoked, the code marked used.
        assert auth.count_credentials() == 0
        used = db.get_conn().execute(
            "SELECT used, redeemed_at FROM recovery_codes WHERE code_hash = ?",
            (hashlib.sha256(codes[0].encode()).hexdigest(),),
        ).fetchone()
        assert used["used"] == 1
        assert used["redeemed_at"] is not None

        # The scoped session reaches the re-enrollment UI only.
        assert client.get("/setup").status_code == 200
        assert client.post("/api/setup/options").status_code == 200

        # ...never bookmarks, /api/auth/* or /api/recovery/*.
        assert client.get("/").status_code == 403
        assert client.get("/api/search").status_code == 403
        assert client.post("/api/auth/options").status_code == 403
        assert client.post("/api/recovery/regenerate").status_code == 403

        # Re-register a brand-new passkey through the setup flow.
        re_resp = register_passkey(client)
        assert re_resp.status_code == 200, re_resp.text
        assert len(re_resp.json()["codes"]) == 10
        # Old credentials were revoked; exactly the new one remains.
        assert auth.count_credentials() == 1
        # The redeemed code stays used (fresh codes are the re-registration's).
        used_again = db.get_conn().execute(
            "SELECT COUNT(*) AS n FROM recovery_codes WHERE used = 1"
        ).fetchone()["n"]
        assert used_again == 1


def test_redeem_revokes_all_pre_existing_sessions_and_survives(fresh_db):
    """The revocation wipes every pre-existing session (normal ones AND a
    stale recovery session from an earlier aborted attempt), while the
    just-created scoped session is never among the casualties."""
    with TestClient(app) as client:
        resp = register_passkey(client)
        codes = resp.json()["codes"]
        auth.create_session(scope="normal")
        auth.create_session(scope="normal")
        stale_recovery = auth.create_session(scope="recovery")
        redeem = _redeem(client, codes[0])
        assert redeem.status_code == 200, redeem.text
    rows = db.get_conn().execute("SELECT id, scope FROM sessions").fetchall()
    assert len(rows) == 1
    assert rows[0]["scope"] == "recovery"
    assert rows[0]["id"] != stale_recovery


# ---------------------------------------------------------------------------
# Failure: used / unknown / missing code -> 400
# ---------------------------------------------------------------------------


def test_used_code_rejected_on_second_redeem(fresh_db):
    with TestClient(app) as client:
        codes = register_passkey(client).json()["codes"]
        code = codes[0]
        assert _redeem(client, code).status_code == 200
        # The SAME code is single-use: a second redeem is rejected.
        resp = _redeem(client, code)
        assert resp.status_code == 400
        assert "code" in resp.json()["detail"].lower()
        # Unknown and missing codes are rejected the same way.
        assert _redeem(client, "not-a-real-code").status_code == 400
        assert client.post("/api/recovery/redeem", json={}).status_code == 400


def test_redeem_rejects_malformed_body(fresh_db):
    with TestClient(app) as client:
        resp = client.post(
            "/api/recovery/redeem",
            content="this is not json",
            headers={"Content-Type": "application/json"},
        )
    assert resp.status_code == 400


# ---------------------------------------------------------------------------
# Expired scoped session: grants nothing, cannot complete re-enrollment
# ---------------------------------------------------------------------------


def test_expired_recovery_session_grants_nothing_and_cannot_reenroll(fresh_db):
    """Once the 10-minute scoped session lapses the stale cookie is inert:
    protected routes 401 (the middleware treats the gone/expired session as
    no session), and the post-recovery race closure blocks /api/setup/verify
    (claimed + revoked credentials + no valid recovery session must not be
    anonymously claimable)."""
    with TestClient(app) as client:
        codes = register_passkey(client).json()["codes"]
        assert _redeem(client, codes[0]).status_code == 200
        scoped_sid = client.cookies.get(auth.SESSION_COOKIE_NAME)
        with db.transaction() as conn:
            conn.execute(
                "UPDATE sessions SET expires_at = ? WHERE id = ?",
                (int(time.time()) - 10, scoped_sid),
            )
        # The stale cookie grants nothing on protected routes (401).
        assert client.get("/api/search").status_code == 401
        # Registration OPTIONS stay open (no credentials exist) but the
        # ceremony cannot COMPLETE without a valid recovery session.
        options = client.post("/api/setup/options")
        assert options.status_code == 200
        challenge = _b64url_decode(options.json()["challenge"])
        credential = build_registration_response(challenge)
        assert client.post("/api/setup/verify", json=credential).status_code == 403


# ---------------------------------------------------------------------------
# Failed re-registration: no extra state consumed, scoped session survives
# ---------------------------------------------------------------------------


def test_failed_reenrollment_preserves_scoped_session_and_single_code_use(fresh_db):
    """A registration that fails verification consumes only its challenge, not
    another recovery code: exactly one code stays used, credentials stay
    revoked, the scoped session stays valid, and a correct retry succeeds."""
    with TestClient(app) as client:
        codes = register_passkey(client).json()["codes"]
        assert _redeem(client, codes[0]).status_code == 200

        options = client.post("/api/setup/options")
        assert options.status_code == 200
        challenge = _b64url_decode(options.json()["challenge"])
        bad = build_registration_response(challenge, rp_id="evil.example")
        resp = client.post("/api/setup/verify", json=bad)
        assert resp.status_code == 400

        # Exactly one code used; no credential registered; scoped session live.
        used = db.get_conn().execute(
            "SELECT COUNT(*) AS n FROM recovery_codes WHERE used = 1"
        ).fetchone()["n"]
        assert used == 1
        assert auth.count_credentials() == 0
        assert client.get("/setup").status_code == 200
        assert client.post("/api/setup/options").status_code == 200

        # The correct ceremony still succeeds within the scoped window.
        retry = register_passkey(client)
        assert retry.status_code == 200, retry.text
        assert auth.count_credentials() == 1


# ---------------------------------------------------------------------------
# Recovery-scoped 403 matrix: HTML link body + JSON detail
# ---------------------------------------------------------------------------


def test_recovery_scoped_session_rejected_on_recovery_regenerate(fresh_db):
    """POST /api/recovery/regenerate is NOT in the scoped-session allow-list
    (redeem is the only /api/recovery/* path a recovery session may use). The
    middleware rejects it with 403 BEFORE routing — the endpoint itself lands
    in todo 12, so a bare request would otherwise 404."""
    with TestClient(app) as client:
        sid = auth.create_session(scope="recovery")
        client.cookies.set(auth.SESSION_COOKIE_NAME, sid)
        resp = client.post("/api/recovery/regenerate")
        assert resp.status_code == 403
        # The whole /api/recovery/* prefix is off-limits, not just regenerate.
        assert client.get("/api/recovery/anything").status_code == 403
    auth.logout(sid)


def test_recovery_403_renders_setup_link_for_html_requests(fresh_db):
    """An HTML client blocked by the recovery pinning gets a small page whose
    only job is pointing at /setup; API clients keep the JSON detail."""
    with TestClient(app) as client:
        sid = auth.create_session(scope="recovery")
        client.cookies.set(auth.SESSION_COOKIE_NAME, sid)
        resp = client.get("/api/search", headers={"Accept": "text/html"})
        assert resp.status_code == 403
        assert "text/html" in resp.headers["content-type"]
        assert 'href="/setup"' in resp.text
        resp = client.get("/api/search")
        assert resp.status_code == 403
        assert resp.json() == {"detail": "Forbidden"}
    auth.logout(sid)


# ---------------------------------------------------------------------------
# Redeem response shape: 303 redirect for HTML, {"next": "/setup"} for API
# ---------------------------------------------------------------------------


def test_redeem_html_accept_redirects_303_to_setup(fresh_db):
    with TestClient(app, follow_redirects=False) as client:
        codes = register_passkey(client).json()["codes"]
        resp = _redeem(client, codes[0], headers={"Accept": "text/html"})
        assert resp.status_code == 303
        assert resp.headers["location"] == "/setup"
        # The scoped session cookie is still set on the redirect.
        scoped_sid = client.cookies.get(auth.SESSION_COOKIE_NAME)
        assert scoped_sid is not None
        row = db.get_conn().execute(
            "SELECT scope FROM sessions WHERE id = ?", (scoped_sid,)
        ).fetchone()
        assert row["scope"] == "recovery"


def test_redeem_reachable_without_session(fresh_db):
    """Redeem is the only /api/recovery/* route exempt from auth: it never
    401s, even with zero credentials/sessions on disk (fresh_db)."""
    with TestClient(app) as client:
        resp = client.post(
            "/api/recovery/redeem",
            json={"code": "whatever"},
        )
        assert resp.status_code != 401


# ---------------------------------------------------------------------------
# CLI: bookmarks-reset-auth escape hatch
# ---------------------------------------------------------------------------


def test_reset_auth_clears_state_and_returns_to_first_run(fresh_db):
    """The CLI escape hatch empties credentials/sessions/codes and clears
    setup_claimed: GET /setup serves the page again and a fresh registration
    succeeds."""
    with TestClient(app) as client:
        resp = register_passkey(client)
        assert resp.status_code == 200
        auth.issue_codes()  # a second batch, so the codes table has rows
        auth.create_session(scope="normal")
        assert auth.count_credentials() == 1
        claimed = db.get_conn().execute(
            "SELECT setup_claimed FROM users WHERE id = 1"
        ).fetchone()["setup_claimed"]
        assert claimed == 1

        from app.reset_auth import reset_auth

        reset_auth()

        # DB is back to first-run state.
        row = db.get_conn().execute(
            "SELECT setup_claimed FROM users WHERE id = 1"
        ).fetchone()
        assert row is not None and row["setup_claimed"] == 0
        assert (
            db.get_conn().execute("SELECT COUNT(*) AS n FROM passkey_credentials").fetchone()["n"]
            == 0
        )
        assert db.get_conn().execute("SELECT COUNT(*) AS n FROM sessions").fetchone()["n"] == 0
        assert (
            db.get_conn().execute("SELECT COUNT(*) AS n FROM recovery_codes").fetchone()["n"] == 0
        )

        # GET /setup serves the page and the ceremony works again.
        assert client.get("/setup").status_code == 200
        re_resp = register_passkey(client)
        assert re_resp.status_code == 200
        assert auth.count_credentials() == 1
        assert len(re_resp.json()["codes"]) == 10


def test_reset_auth_cli_main_with_yes_flag(fresh_db):
    from app.reset_auth import main

    with TestClient(app) as client:
        register_passkey(client)
        assert main(["--yes"]) == 0
        assert auth.count_credentials() == 0
        claimed = db.get_conn().execute(
            "SELECT setup_claimed FROM users WHERE id = 1"
        ).fetchone()["setup_claimed"]
        assert claimed == 0
