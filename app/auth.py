"""Shared authentication helpers for the passkey flow.

This module is the **single home** for the first-run registration bootstrap
(todo 9) and for helpers later todos build on:

- ``issue_codes()`` — generate 10 one-time recovery codes via
  ``secrets.token_urlsafe``, store their SHA-256 hashes in ``recovery_codes``
  and return the plaintext codes exactly once. Todos 11 (rotation) and 12
  (regeneration) reuse this helper; there is no second generation/hash path.
- Registration: options generation, challenge storage/consumption (single-use,
  5-minute TTL), registration verification and credential persistence.
- ``create_session()`` — session row creation (the first post-setup session has
  scope ``'normal'``).

The server-side setup guard lives in the endpoints (``/api/setup/*`` is in the
global unauthenticated-exemption list, so it cannot rely on auth middleware).
The predicates here implement that guard: setup is allowed only while no
credential exists, and once ``setup_claimed`` is set only a valid
recovery-scoped session re-opens it (closing the post-recovery race).

Credential material, challenge bytes and recovery codes are never logged.
Every write goes through ``db.transaction()`` (BEGIN IMMEDIATE) on the calling
thread's connection; async callers reach these functions via ``db.run_db``.
"""

from __future__ import annotations

import hashlib
import json
import secrets
import time

from webauthn import (
    generate_registration_options,
    options_to_json,
    verify_registration_response,
)
from webauthn.helpers.decode_credential_public_key import decode_credential_public_key
from webauthn.helpers.exceptions import WebAuthnException
from webauthn.helpers.parse_client_data_json import parse_client_data_json
from webauthn.helpers.parse_registration_credential_json import (
    parse_registration_credential_json,
)
from webauthn.helpers.structs import (
    AttestationConveyancePreference,
    AuthenticatorSelectionCriteria,
    CredentialDeviceType,
    PublicKeyCredentialCreationOptions,
    RegistrationCredential,
    ResidentKeyRequirement,
    UserVerificationRequirement,
)

from app import config, db

# The fixed single-user row (users.id = 1); its 1-byte user handle mirrors it.
USER_ID = 1
USER_HANDLE = b"\x01"

# Informational identity shown by authenticators during registration.
USER_NAME = "bookmarks"
USER_DISPLAY_NAME = "Bookmarks"

SESSION_COOKIE_NAME = "session"

REGISTRATION_PURPOSE = "registration"
CHALLENGE_TTL_SECONDS = 5 * 60  # 5-minute TTL

RECOVERY_CODE_COUNT = 10


class SetupError(Exception):
    """A setup registration could not proceed (bad body, stale challenge, ...)."""


# ---------------------------------------------------------------------------
# Setup guard predicates
# ---------------------------------------------------------------------------


def count_credentials() -> int:
    """Number of stored passkey credentials (any authenticator)."""
    row = db.get_conn().execute(
        "SELECT COUNT(*) AS n FROM passkey_credentials"
    ).fetchone()
    return int(row["n"])


def setup_claimed() -> bool:
    """Whether the first-run setup has ever completed successfully."""
    row = db.get_conn().execute(
        "SELECT setup_claimed FROM users WHERE id = ?", (USER_ID,)
    ).fetchone()
    return bool(row and row["setup_claimed"])


def has_valid_recovery_session() -> bool:
    """A recovery-scoped session that has not yet expired."""
    row = db.get_conn().execute(
        "SELECT id FROM sessions WHERE scope = 'recovery' AND expires_at > ?",
        (int(time.time()),),
    ).fetchone()
    return row is not None


def setup_options_allowed() -> bool:
    """Guard for POST /api/setup/options: reject when a credential exists and no
    valid recovery-scoped session is present.

    The recovery flow revokes every credential before re-enrollment, so when a
    recovery session is live the credential table is empty — this predicate is
    exactly "not (credentials exist and no recovery session)".
    """
    return not (count_credentials() > 0 and not has_valid_recovery_session())


def setup_verify_allowed() -> bool:
    """Guard for POST /api/setup/verify: require *credentials empty* AND
    *(never claimed OR valid recovery-scoped session)*.

    Once setup is claimed, a revoked-and-empty credential table is only
    re-claimable through a live recovery session. This closes the post-recovery
    race where revoked credentials + a consumed code would otherwise leave the
    app anonymously claimable after the scoped session expires.
    """
    if count_credentials() > 0:
        return False
    return (not setup_claimed()) or has_valid_recovery_session()


# ---------------------------------------------------------------------------
# Registration options + challenge lifecycle
# ---------------------------------------------------------------------------


def registration_options() -> dict:
    """Build registration options for the fixed user and store the challenge.

    resident_key=REQUIRED (discoverable/usernameless), user_verification=REQUIRED,
    attestation=none, rp_id from config. Returns the L3 JSON options dict.
    """
    challenge = secrets.token_bytes(32)
    options: PublicKeyCredentialCreationOptions = generate_registration_options(
        rp_id=config.WEBAUTHN_RP_ID,
        rp_name=config.WEBAUTHN_RP_NAME,
        user_name=USER_NAME,
        user_display_name=USER_DISPLAY_NAME,
        user_id=USER_HANDLE,
        challenge=challenge,
        timeout=60_000,
        attestation=AttestationConveyancePreference.NONE,
        authenticator_selection=AuthenticatorSelectionCriteria(
            resident_key=ResidentKeyRequirement.REQUIRED,
            user_verification=UserVerificationRequirement.REQUIRED,
        ),
    )
    store_challenge(challenge, purpose=REGISTRATION_PURPOSE)
    return json.loads(options_to_json(options))


def store_challenge(challenge: bytes, *, purpose: str) -> None:
    """Persist an in-flight challenge with a 5-minute TTL."""
    with db.transaction() as conn:
        conn.execute(
            "INSERT INTO webauthn_challenges (challenge, purpose, expires_at) "
            "VALUES (?, ?, ?)",
            (challenge, purpose, int(time.time()) + CHALLENGE_TTL_SECONDS),
        )


def consume_challenge(challenge: bytes, *, purpose: str) -> bool:
    """Consume a stored challenge for a purpose. Single-use: the row is deleted
    on sight (even when expired), and only an existing, unexpired challenge is
    accepted. Returns whether the challenge was valid."""
    with db.transaction() as conn:
        row = conn.execute(
            "SELECT expires_at FROM webauthn_challenges "
            "WHERE challenge = ? AND purpose = ?",
            (challenge, purpose),
        ).fetchone()
        if row is None:
            return False
        conn.execute("DELETE FROM webauthn_challenges WHERE challenge = ?", (challenge,))
        return row["expires_at"] > int(time.time())


# ---------------------------------------------------------------------------
# Registration verification + persistence
# ---------------------------------------------------------------------------


def complete_registration(json_body: str | dict) -> tuple[list[str], str]:
    """Verify a registration response, persist the credential, claim setup,
    issue the recovery codes and create the first normal-scoped session.

    Returns ``(recovery_codes, session_id)``. The challenge is consumed
    (single-use) before verification. Raises :class:`SetupError` on any failure.
    """
    try:
        credential = parse_registration_credential_json(json_body)
    except WebAuthnException as exc:
        raise SetupError("malformed registration response") from exc

    client_data = parse_client_data_json(credential.response.client_data_json)
    challenge = client_data.challenge
    if not consume_challenge(challenge, purpose=REGISTRATION_PURPOSE):
        raise SetupError("challenge is unknown, expired or already used")

    try:
        verified = verify_registration_response(
            credential=credential,
            expected_challenge=challenge,
            expected_rp_id=config.WEBAUTHN_RP_ID,
            expected_origin=config.PUBLIC_ORIGIN,
            require_user_verification=True,
        )
    except WebAuthnException as exc:
        raise SetupError(f"registration response failed verification: {exc}") from exc

    store_credential(credential, verified)
    set_setup_claimed()
    codes = issue_codes()
    session_id = create_session(scope="normal")
    return codes, session_id


def store_credential(credential: RegistrationCredential, verified) -> None:
    """Persist a verified registration (public key, COSE alg, BE/BS, transports)."""
    transports = json.dumps(
        [t.value for t in credential.response.transports]
        if credential.response.transports
        else []
    )
    cose_alg = int(decode_credential_public_key(verified.credential_public_key).alg)
    now = int(time.time())
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
                verified.credential_id,
                verified.credential_public_key,
                cose_alg,
                verified.sign_count,
                bytes.fromhex(verified.aaguid.replace("-", "")),
                transports,
                1 if verified.credential_device_type == CredentialDeviceType.MULTI_DEVICE else 0,
                1 if verified.credential_backed_up else 0,
                USER_HANDLE,
                "",
                now,
                now,
            ),
        )


def set_setup_claimed() -> None:
    """Mark the first-run setup as claimed on the fixed users row."""
    with db.transaction() as conn:
        conn.execute(
            "UPDATE users SET setup_claimed = 1 WHERE id = ?", (USER_ID,)
        )


# ---------------------------------------------------------------------------
# Recovery codes + sessions
# ---------------------------------------------------------------------------


def issue_codes() -> list[str]:
    """Generate 10 fresh one-time recovery codes.

    Returns the plaintext codes exactly once; only SHA-256 hashes are stored.
    This is the single generation/hash path — todos 11 (rotation) and 12
    (regeneration) call this helper rather than duplicating it.
    """
    now = int(time.time())
    codes = [secrets.token_urlsafe(16) for _ in range(RECOVERY_CODE_COUNT)]
    with db.transaction() as conn:
        conn.executemany(
            "INSERT INTO recovery_codes (code_hash, created_at) VALUES (?, ?)",
            ((hashlib.sha256(code.encode()).hexdigest(), now) for code in codes),
        )
    return codes


def create_session(*, scope: str = "normal") -> str:
    """Create a session row and return its opaque id."""
    session_id = secrets.token_urlsafe(32)
    csrf_token = secrets.token_urlsafe(32)
    now = int(time.time())
    with db.transaction() as conn:
        conn.execute(
            "INSERT INTO sessions (id, csrf_token, scope, created_at, expires_at) "
            "VALUES (?, ?, ?, ?, ?)",
            (session_id, csrf_token, scope, now, now + config.SESSION_TTL_SECONDS),
        )
    return session_id
