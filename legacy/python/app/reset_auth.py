"""CLI escape hatch: reset all passkey auth state to the first-run /setup state.

Deletes every row in ``passkey_credentials``, ``sessions`` and
``recovery_codes`` and clears the ``setup_claimed`` marker, so the app serves
the first-run bootstrap page again. This is the documented self-hosted
recovery path — use it only when passkeys and recovery codes are both lost.

    uv run bookmarks-reset-auth            # prompts for confirmation
    uv run bookmarks-reset-auth --yes      # non-interactive (scripts)
"""

from __future__ import annotations

import argparse
import logging
import sys
from collections.abc import Iterable

from . import auth, db

log = logging.getLogger("bookmarks.reset_auth")


def reset_auth() -> None:
    """Empty the auth tables and clear setup_claimed (single transaction)."""
    with db.transaction() as conn:
        conn.execute("DELETE FROM passkey_credentials")
        conn.execute("DELETE FROM sessions")
        conn.execute("DELETE FROM recovery_codes")
        conn.execute(
            "UPDATE users SET setup_claimed = 0 WHERE id = ?", (auth.USER_ID,)
        )


def _parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Reset all passkey auth state (credentials, sessions, "
        "recovery codes) and return the app to the first-run /setup state.",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="skip the confirmation prompt (non-interactive)",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="Debug logging")
    return parser.parse_args(list(argv))


def main(argv: Iterable[str] | None = None) -> int:
    args = _parse_args(argv if argv is not None else sys.argv[1:])
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    if not args.yes:
        answer = input(
            "This deletes all passkeys, sessions and recovery codes and "
            "returns the app to first-run setup. Continue? [y/N] "
        )
        if answer.strip().lower() not in ("y", "yes"):
            print("Aborted.")
            return 1
    reset_auth()
    log.info(
        "auth reset: credentials, sessions and recovery codes cleared; "
        "setup_claimed=0; app returns to /setup"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
