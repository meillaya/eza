"""Seed passkey credentials directly into the app DB for the e2e harness.

The browser's CDP virtual authenticator must hold the SAME key pair the app
stores, so this helper generates one EC P-256 pair, writes the COSE public key
into ``passkey_credentials`` (the same shape ``auth.store_credential`` writes)
and prints the PKCS8 DER private key (CDP base64) plus the credential id for
the CDP ``WebAuthn.addCredential`` call.

Subcommands:

- (none)        seed one credential; print its CDP-facing JSON
- ``list``      dump every credential row (id, sign_count, BE, last_used_at)
- ``bump``      force every stored sign_count (stale-counter simulation)
"""

from __future__ import annotations

import argparse
import base64
import json
import secrets
import sqlite3
import sys
import time

import cbor2
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec


def _b64(data: bytes) -> str:
    # CDP WebAuthn `binary` fields are STANDARD base64 (with padding).
    return base64.b64encode(data).decode()


def _cose_public_key(private_key: ec.EllipticCurvePrivateKey) -> bytes:
    """COSE-encoded ECDSA P-256 public key (ES256, alg -7), like the app's
    ``tests/test_auth.py:_cose_public_key``."""
    public_numbers = private_key.public_key().public_numbers()
    x = public_numbers.x.to_bytes(32, "big")
    y = public_numbers.y.to_bytes(32, "big")
    return cbor2.dumps({1: 2, 3: -7, -1: 1, -2: x, -3: y})


def seed(db_path: str, backup_eligible: bool, user_handle_value: int) -> dict:
    credential_id = secrets.token_bytes(32)
    user_handle = bytes([user_handle_value])
    private_key = ec.generate_private_key(ec.SECP256R1())
    der = private_key.private_bytes(
        serialization.Encoding.DER,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    now = int(time.time())
    be = int(backup_eligible)
    with sqlite3.connect(db_path, timeout=5) as conn:
        conn.execute(
            "INSERT INTO passkey_credentials ("
            "credential_id, public_key, cose_alg, sign_count, aaguid, transports, "
            "backup_eligible, backup_state, user_handle, nickname, created_at, last_used_at"
            ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                credential_id,
                _cose_public_key(private_key),
                -7,
                1,
                b"\x00" * 16,
                '["internal"]',
                be,
                be,
                user_handle,
                "",
                now,
                now,
            ),
        )
    return {
        "credentialId": _b64(credential_id),
        "userHandle": _b64(user_handle),
        "privateKey": _b64(der),
        "signCount": 1,
        "backupEligibility": backup_eligible,
    }


def list_credentials(db_path: str) -> list[dict]:
    rows: list[dict] = []
    with sqlite3.connect(db_path, timeout=5) as conn:
        for credential_id, sign_count, backup_eligible, last_used_at in conn.execute(
            "SELECT credential_id, sign_count, backup_eligible, last_used_at "
            "FROM passkey_credentials ORDER BY credential_id"
        ):
            rows.append(
                {
                    "credentialId": _b64(credential_id),
                    "signCount": sign_count,
                    "backupEligibility": bool(backup_eligible),
                    "lastUsedAt": last_used_at,
                }
            )
    return rows


def bump_sign_count(db_path: str, sign_count: int) -> None:
    with sqlite3.connect(db_path, timeout=5) as conn:
        conn.execute("UPDATE passkey_credentials SET sign_count = ?", (sign_count,))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True, help="path to the app SQLite DB")
    parser.add_argument("--be", type=int, default=1, help="backup_eligible flag (0/1)")
    parser.add_argument(
        "--user-handle",
        type=int,
        default=1,
        help="single-byte user handle; must differ per virtual-authenticator credential",
    )
    sub = parser.add_subparsers(dest="action")
    sub.add_parser("list", help="dump credential rows as JSON")
    sub.add_parser("bump").add_argument("--sign-count", type=int, required=True)
    args = parser.parse_args()

    if args.action == "list":
        print(json.dumps({"credentials": list_credentials(args.db)}))
        return 0
    if args.action == "bump":
        bump_sign_count(args.db, args.sign_count)
        return 0
    result = seed(args.db, bool(args.be), args.user_handle)
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
