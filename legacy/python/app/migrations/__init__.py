"""Versioned SQLite migrations, applied by the runner in :mod:`app.db`.

Each migration lives in its own module named ``mNNNN_<slug>.py`` and exposes a
single ``migrate(conn)`` function. ``MIGRATIONS`` orders the steps by
filename; a step's version number is its 1-based index in that list.

To add a migration, append a new ``mNNNN_<slug>.py`` module (pick the next
free number — that is the version) and export ``migrate(conn)`` from it. Never
edit a module after it has shipped; additive migrations are append-only.

Version 1 (``m0001_baseline_last_checked``) is the detect-and-stamp baseline:
on an unversioned (``user_version`` = 0) database it reconciles the
pre-versioning schema instead of blindly re-running the legacy probe, and the
runner stamps ``PRAGMA user_version = 1``.
"""

from __future__ import annotations

import importlib
import pkgutil
import re
import sqlite3
from collections.abc import Callable
from typing import cast

_MIGRATION_FILE = re.compile(r"^m\d{4}_[a-z0-9_]+$")


def _load_migrations() -> list[tuple[str, Callable[[sqlite3.Connection], None]]]:
    """Import every ``mNNNN_*.py`` module in this package, filename-sorted."""
    steps: list[tuple[str, Callable[[sqlite3.Connection], None]]] = []
    for info in sorted(pkgutil.iter_modules(__path__), key=lambda m: m.name):
        if not _MIGRATION_FILE.match(info.name):
            continue
        module = importlib.import_module(f"{__name__}.{info.name}")
        migrate = getattr(module, "migrate", None)
        if not callable(migrate):
            raise ImportError(f"{__name__}.{info.name} must define migrate(conn)")
        steps.append((info.name, cast(Callable[[sqlite3.Connection], None], migrate)))
    return steps


MIGRATIONS: list[tuple[str, Callable[[sqlite3.Connection], None]]] = _load_migrations()
