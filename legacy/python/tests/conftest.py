"""Shared pytest fixtures.

The DB module uses a module-level singleton connection. Tests need an
isolated database per test, so we reset DB_PATH and the cached connection
on each fixture setup.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from app import db


@pytest.fixture
def db_path(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Redirect the DB to a temp file and reset the module-level connection."""
    p = tmp_path / "test.db"
    monkeypatch.setattr(db, "DB_PATH", p)
    monkeypatch.setattr(db, "_conn", None)
    return p


@pytest.fixture
def fresh_db(db_path: Path):
    """Initialize the schema on a fresh temp DB."""
    db.get_conn()
    return db
