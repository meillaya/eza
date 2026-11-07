"""GET /health — deploy probe tests.

The endpoint must be reachable without auth (auth is a wave-2 feature) and
must never expose bookmark data. It answers 200 only when a ``SELECT 1``
round-trip through the DB connection succeeds; a missing/corrupt DB yields
503 so load balancers can route around a broken instance.
"""

from __future__ import annotations

import sqlite3

from fastapi.testclient import TestClient

from app import db
from app.main import app


def test_health_ok(fresh_db) -> None:
    with TestClient(app) as client:
        resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_health_unavailable_when_conn_raises(monkeypatch) -> None:
    def boom() -> None:
        raise sqlite3.OperationalError("unable to open database file")

    monkeypatch.setattr(db, "get_conn", boom)
    with TestClient(app) as client:
        resp = client.get("/health")
    assert resp.status_code == 503
    assert resp.json() == {"status": "unavailable", "detail": "database unreachable"}


def test_health_unavailable_when_db_unreadable(tmp_path, monkeypatch) -> None:
    """Point BOOKMARKS_DB at an unopenable path (a directory) and reset the
    cached connection state so the next get_conn() actually reconnects."""
    (tmp_path / "not-a-db").mkdir()
    monkeypatch.setattr(db, "DB_PATH", tmp_path / "not-a-db")
    monkeypatch.setattr(db, "_conn", None)
    with TestClient(app) as client:
        resp = client.get("/health")
    assert resp.status_code == 503
    assert resp.json() == {"status": "unavailable", "detail": "database unreachable"}
