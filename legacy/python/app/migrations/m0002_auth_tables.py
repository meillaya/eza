"""Migration 2 — auth scaffolding: credentials, sessions, challenges, recovery codes.

Adds the five tables the passwordless flow needs, in a single append-only
step. The runner wraps this migration in a transaction and stamps
``PRAGMA user_version = 2``, so it applies exactly once per database.

- ``users`` — single fixed row (``id = 1``) plus ``setup_claimed``, the flag
  the server-side setup guard (todo 9) and the account-reset flow (todo 11)
  rely on. Row creation is idempotent-guarded so the step stays re-runnable.
- ``passkey_credentials`` — one row per enrolled authenticator. ``credential_id``
  is the stable key handed back by the WebAuthn ceremony (BLOB, UNIQUE);
  BLOBs hold the raw CBOR bytes; ``transports`` is a JSON array of strings.
- ``webauthn_challenges`` — challenges in flight during a ceremony, tagged with
  a purpose (registration / authentication / recovery) and an expiry.
- ``sessions`` — login sessions keyed by an opaque token. ``scope``
  (default ``normal``) is REQUIRED for the recovery scoped-session in todo 11.
- ``recovery_codes`` — one-time recovery codes stored hashed (``code_hash``
  UNIQUE); ``redeemed_at`` stays NULL until a code is consumed.
"""

from __future__ import annotations

import sqlite3


def migrate(conn: sqlite3.Connection) -> None:
    """Create the v2 auth tables and the fixed users row."""
    conn.execute(
        """
        CREATE TABLE users (
            id            INTEGER PRIMARY KEY,
            setup_claimed INTEGER NOT NULL DEFAULT 0
        )
        """
    )
    conn.execute("INSERT OR IGNORE INTO users (id, setup_claimed) VALUES (1, 0)")
    conn.execute(
        """
        CREATE TABLE passkey_credentials (
            credential_id   BLOB    NOT NULL UNIQUE,
            public_key      BLOB    NOT NULL,
            cose_alg        INTEGER NOT NULL,
            sign_count      INTEGER NOT NULL DEFAULT 0,
            aaguid          BLOB,
            transports      TEXT    NOT NULL DEFAULT '[]',
            backup_eligible INTEGER NOT NULL DEFAULT 0,
            backup_state    INTEGER NOT NULL DEFAULT 0,
            user_handle     BLOB,
            nickname        TEXT    NOT NULL DEFAULT '',
            created_at      INTEGER NOT NULL,
            last_used_at    INTEGER
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE webauthn_challenges (
            challenge  BLOB    PRIMARY KEY,
            purpose    TEXT    NOT NULL,
            expires_at INTEGER NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE sessions (
            id         TEXT    PRIMARY KEY,
            csrf_token TEXT    NOT NULL,
            scope      TEXT    NOT NULL DEFAULT 'normal',
            created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE recovery_codes (
            code_hash   TEXT    NOT NULL UNIQUE,
            used        INTEGER NOT NULL DEFAULT 0,
            created_at  INTEGER NOT NULL,
            redeemed_at INTEGER
        )
        """
    )
