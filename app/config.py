"""Environment-driven configuration, stdlib only.

Every setting is read from ``os.environ`` once, at import time. No third-party
dependencies, no .env file loader — the process environment is the source of
truth (use a wrapper script, systemd unit, or ``export`` in your shell).

Prod vs dev is derived from the ``PUBLIC_ORIGIN`` host: anything that isn't a
loopback host (``127.0.0.1`` / ``localhost``) is treated as production.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path
from urllib.parse import urlparse

logger = logging.getLogger(__name__)

_REPO_ROOT = Path(__file__).resolve().parent.parent
_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost"})
_DEFAULT_SESSION_TTL = 2592000  # 30 days, seconds


def _env_path(name: str, default: str | None) -> Path | None:
    """Read an env var as a path, or ``None`` when unset and no default given."""
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return Path(default) if default is not None else None
    return Path(raw).expanduser()


def _default_rp_id(host: str) -> str:
    """Best-effort registrable domain from a host, stdlib only.

    Loopback hosts map to ``localhost`` (the WebAuthn-conformant dev RP ID).
    For real hosts we strip a leading ``www.`` — a full public-suffix table is
    out of scope, so subdomain deployments should set ``WEBAUTHN_RP_ID``
    explicitly. IP addresses are kept as-is (valid RP IDs for IP origins).
    """
    if host in _LOOPBACK_HOSTS:
        return "localhost"
    return host[4:] if host.startswith("www.") else host


# ---------------------------------------------------------------------------
# Core settings
# ---------------------------------------------------------------------------

PUBLIC_ORIGIN = os.environ.get("PUBLIC_ORIGIN", "http://localhost:8000").rstrip("/")

PUBLIC_HOST = (urlparse(PUBLIC_ORIGIN).hostname or "localhost").lower()

# The prod predicate: loopback origins are dev, everything else is prod.
# Drives the SECRET_KEY warning below and the session-cookie Secure flag.
IS_PROD = PUBLIC_HOST not in _LOOPBACK_HOSTS

BOOKMARKS_DB = _env_path("BOOKMARKS_DB", str(_REPO_ROOT / "data" / "bookmarks.db"))
assert BOOKMARKS_DB is not None  # the default is always present

WEBAUTHN_RP_ID = os.environ.get("WEBAUTHN_RP_ID", _default_rp_id(PUBLIC_HOST))
WEBAUTHN_RP_NAME = os.environ.get("WEBAUTHN_RP_NAME", "Bookmarks")

_raw_ttl = os.environ.get("SESSION_TTL_SECONDS")
try:
    SESSION_TTL_SECONDS = int(_raw_ttl) if _raw_ttl is not None else _DEFAULT_SESSION_TTL
except ValueError:
    logger.warning(
        "SESSION_TTL_SECONDS=%r is not an integer; falling back to %d",
        _raw_ttl,
        _DEFAULT_SESSION_TTL,
    )
    SESSION_TTL_SECONDS = _DEFAULT_SESSION_TTL

SECRET_KEY = os.environ.get("SECRET_KEY", "")
if not SECRET_KEY:
    SECRET_KEY = "dev-insecure-secret-change-me"
    if IS_PROD:
        logger.warning(
            "SECRET_KEY is NOT set and PUBLIC_ORIGIN=%s looks like production! "
            "Using an insecure default — set SECRET_KEY in the environment.",
            PUBLIC_ORIGIN,
        )

# ---------------------------------------------------------------------------
# Backups (optional)
# ---------------------------------------------------------------------------

BACKUP_DIR = _env_path("BACKUP_DIR", str(_REPO_ROOT / "data" / "backups"))
assert BACKUP_DIR is not None  # the default is always present

BACKUP_OFFBOX_DEST = _env_path("BACKUP_OFFBOX_DEST", None)

# ---------------------------------------------------------------------------
# Startup side effects
# ---------------------------------------------------------------------------

# Startup side effect: guarantee the DB dir exists before anything connects.
BOOKMARKS_DB.parent.mkdir(parents=True, exist_ok=True)

# ---------------------------------------------------------------------------
# Netscape HTML export (todo 31)
# ---------------------------------------------------------------------------

# The tag whose bookmarks land in the exported file's toolbar folder
# (<H3 PERSONAL_TOOLBAR_FOLDER="true">) — Chromium's "Bookmarks bar". Every
# other bookmark is the flattened "Other bucket" (written one level up).
EXPORT_TOOLBAR_TAG = os.environ.get("EXPORT_TOOLBAR_TAG", "toolbar").strip().lower()
