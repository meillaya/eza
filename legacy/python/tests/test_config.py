"""Tests for the env-driven configuration module.

The config module reads ``os.environ`` at import time, so tests that need a
different environment reload the module after patching the environment.
"""

from __future__ import annotations

import importlib
import logging
from pathlib import Path

import pytest

from app import config


@pytest.fixture
def clean_env(monkeypatch: pytest.MonkeyPatch):
    """Remove every config var so the module falls back to defaults."""
    for name in (
        "BOOKMARKS_DB",
        "PUBLIC_ORIGIN",
        "WEBAUTHN_RP_ID",
        "WEBAUTHN_RP_NAME",
        "SESSION_TTL_SECONDS",
        "SECRET_KEY",
        "BACKUP_DIR",
        "BACKUP_OFFBOX_DEST",
    ):
        monkeypatch.delenv(name, raising=False)
    return monkeypatch


def reload_config():
    return importlib.reload(config)


def test_defaults_when_unset(clean_env):
    repo_root = Path(__file__).resolve().parent.parent
    cfg = reload_config()
    assert repo_root / "data" / "bookmarks.db" == cfg.BOOKMARKS_DB
    assert cfg.PUBLIC_ORIGIN == "http://localhost:8000"
    assert cfg.WEBAUTHN_RP_ID == "localhost"
    assert cfg.WEBAUTHN_RP_NAME == "Bookmarks"
    assert cfg.SESSION_TTL_SECONDS == 2592000
    assert cfg.IS_PROD is False
    assert repo_root / "data" / "backups" == cfg.BACKUP_DIR
    assert cfg.BACKUP_OFFBOX_DEST is None


def test_bookmarks_db_env_override(clean_env):
    clean_env.setenv("BOOKMARKS_DB", "/tmp/bm-test.db")
    cfg = reload_config()
    assert Path("/tmp/bm-test.db") == cfg.BOOKMARKS_DB


def test_config_init_creates_parent_dir_for_nested_path(clean_env, tmp_path: Path):
    nested = tmp_path / "sub" / "dir" / "bm.db"
    clean_env.setenv("BOOKMARKS_DB", str(nested))
    reload_config()
    assert nested.parent.is_dir()


def test_prod_predicate_and_rp_id(clean_env):
    clean_env.setenv("PUBLIC_ORIGIN", "https://www.example.com")
    cfg = reload_config()
    assert cfg.IS_PROD is True
    assert cfg.WEBAUTHN_RP_ID == "example.com"


def test_loopback_origins_are_not_prod(clean_env):
    clean_env.setenv("PUBLIC_ORIGIN", "http://127.0.0.1:8000")
    cfg = reload_config()
    assert cfg.IS_PROD is False
    assert cfg.WEBAUTHN_RP_ID == "localhost"


def test_webauthn_rp_id_env_override(clean_env):
    clean_env.setenv("PUBLIC_ORIGIN", "https://app.example.com")
    clean_env.setenv("WEBAUTHN_RP_ID", "example.com")
    cfg = reload_config()
    assert cfg.IS_PROD is True
    assert cfg.WEBAUTHN_RP_ID == "example.com"


def test_session_ttl_env_override(clean_env):
    clean_env.setenv("SESSION_TTL_SECONDS", "3600")
    cfg = reload_config()
    assert cfg.SESSION_TTL_SECONDS == 3600


def test_session_ttl_invalid_falls_back_to_default(clean_env, caplog):
    clean_env.setenv("SESSION_TTL_SECONDS", "not-a-number")
    with caplog.at_level(logging.WARNING, logger="app.config"):
        cfg = reload_config()
    assert cfg.SESSION_TTL_SECONDS == 2592000
    assert any("SESSION_TTL_SECONDS" in r.message for r in caplog.records)


def test_secret_key_warns_when_unset_in_prod(clean_env, caplog):
    clean_env.setenv("PUBLIC_ORIGIN", "https://bm.example.com")
    with caplog.at_level(logging.WARNING, logger="app.config"):
        cfg = reload_config()
    assert cfg.IS_PROD is True
    assert any("SECRET_KEY" in r.message for r in caplog.records)


def test_secret_key_dev_silent_when_not_prod(clean_env, caplog):
    with caplog.at_level(logging.WARNING, logger="app.config"):
        reload_config()
    assert not any("SECRET_KEY" in r.message for r in caplog.records)


def test_backup_offbox_dest_override(clean_env):
    clean_env.setenv("BACKUP_OFFBOX_DEST", "/mnt/offbox/backups")
    cfg = reload_config()
    assert Path("/mnt/offbox/backups") == cfg.BACKUP_OFFBOX_DEST


def test_db_path_monkeypatch_contract_still_works(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
):
    """conftest.py redirects the DB by patching db.DB_PATH / db._conn; that
    contract must keep working after the config migration."""
    from app import db

    p = tmp_path / "nested" / "test.db"
    monkeypatch.setattr(db, "DB_PATH", p)
    monkeypatch.setattr(db, "_conn", None)
    db.get_conn()
    assert p.exists()
