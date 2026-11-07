"""Packaging smoke test (todo 34): the wheel must actually work.

Builds the wheel with ``uv build``, installs it into a FRESH venv, boots
``uvicorn app.main:app`` from that venv against a temp BOOKMARKS_DB and
exercises the real HTTP surface:

- ``/health`` — open, 200 (auth-exempt by design)
- ``/`` unauthenticated — 401, the login page (auth exists)
- ``/static/app.js`` — 200, served from the installed wheel
- ``/`` with a seeded session cookie — 200 with the index template rendered
  (grid markers + the seeded card), which only works when templates/ ships
  in the wheel

The session is seeded as a plain ``sessions`` row, the same shape tests use.
This is the ONLY wheel-content coverage: the e2e harness (todo 13) exercises
the source tree, not the installed package. Skipped only when ``uv`` is not on
PATH; otherwise always run.
"""

from __future__ import annotations

import http.client
import os
import shutil
import socket
import subprocess
import time
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent
_SESSION_ID = "wheel-smoke-session"
_SESSION_COOKIE = f"session={_SESSION_ID}"


def _run(cmd: list[str], *, cwd: Path, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=600
    )
    if proc.returncode != 0:
        raise AssertionError(
            f"command failed: {cmd}\n--- stdout ---\n{proc.stdout}\n--- stderr ---\n{proc.stderr}"
        )
    return proc


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        _, port = s.getsockname()
    assert isinstance(port, int)
    return port


def _get(port: int, path: str, *, cookie: str | None = None) -> tuple[int, str]:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    headers = {"Accept": "text/html"}
    if cookie is not None:
        headers["Cookie"] = cookie
    try:
        conn.request("GET", path, headers=headers)
        resp = conn.getresponse()
        return resp.status, resp.read().decode("utf-8", errors="replace")
    finally:
        conn.close()


def _wait_healthy(port: int, *, timeout: float = 120.0) -> None:
    deadline = time.monotonic() + timeout
    last_status: int | None = None
    while time.monotonic() < deadline:
        try:
            status, _ = _get(port, "/health")
        except OSError:
            time.sleep(0.5)
            continue
        last_status = status
        if status == 200:
            return
        time.sleep(0.5)
    raise AssertionError(
        f"uvicorn never became healthy within {timeout}s (last /health status: {last_status!r})"
    )


def _seed_db(db_path: Path, python: Path, cwd: Path, env: dict[str, str]) -> None:
    """Migrate the fresh DB (via the installed app) and seed a session + a
    bookmark, mirroring how tests create sessions."""
    script = f"""
import sqlite3, time
from app import db
db.get_conn()  # apply schema + migrations on the fresh file
con = sqlite3.connect({str(db_path)!r})
now = int(time.time())
con.execute(
    "INSERT INTO sessions (id, csrf_token, scope, created_at, expires_at) "
    "VALUES (?, ?, 'normal', ?, ?)",
    ({_SESSION_ID!r}, 'tok', now, now + 3600),
)
con.execute(
    "INSERT INTO bookmarks (url, title, domain, created_at) VALUES (?, ?, ?, ?)",
    ('https://wheel-smoke.example/', 'Wheel smoke bookmark', 'wheel-smoke.example', now),
)
con.commit()
con.close()
print('seeded: session + bookmark')
"""
    _ = _run([str(python), "-c", script], cwd=cwd, env=env)


@pytest.mark.skipif(shutil.which("uv") is None, reason="uv not on PATH")
def test_wheel_smoke_renders_from_site_packages(tmp_path: Path) -> None:
    """Given a wheel built and installed into a fresh venv, uvicorn serves the
    app from site-packages: /health open, unauthenticated / is the 401 login
    page, /static serves from the wheel, and a session cookie renders the grid."""
    env = dict(os.environ)
    work = tmp_path / "work"
    work.mkdir()
    db_path = work / "bookmarks.db"
    env["BOOKMARKS_DB"] = str(db_path)

    # Build the wheel into a scratch dir (never the repo's dist/).
    dist_dir = tmp_path / "dist"
    _ = _run(
        ["uv", "build", "--out-dir", str(dist_dir)],
        cwd=_REPO_ROOT,
        env=env,
    )
    wheel = next(dist_dir.glob("bookmarks-*.whl"))

    # Fresh venv + install the wheel (runtime deps come from wheel metadata).
    venv = tmp_path / "venv"
    _ = _run(["uv", "venv", str(venv)], cwd=work, env=env)
    venv_python = venv / "bin" / "python"
    _ = _run(
        ["uv", "pip", "install", "--python", str(venv_python), str(wheel)], cwd=work, env=env
    )

    # Migrate + seed the temp DB using the INSTALLED app package (cwd is the
    # scratch dir, so `app` resolves to site-packages, not the checkout).
    _seed_db(db_path, venv_python, work, env)

    # Boot the installed app with uvicorn from the fresh venv.
    port = _free_port()
    uvicorn = venv / "bin" / "uvicorn"
    log_file = work / "uvicorn.log"
    with log_file.open("w") as log:
        proc = subprocess.Popen(
            [str(uvicorn), "app.main:app", "--host", "127.0.0.1", "--port", str(port)],
            cwd=work,
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
        )
    try:
        try:
            _wait_healthy(port)
        except AssertionError:
            log = log_file.read_text()
            raise AssertionError(f"uvicorn failed to boot:\n{log}") from None

        status, body = _get(port, "/health")
        assert status == 200, body
        assert '"status":"ok"' in body.replace(" ", ""), body

        status, body = _get(port, "/")
        assert status == 401, f"expected 401 login page, got {status}"
        assert "Sign in with your passkey" in body, body

        status, body = _get(port, "/static/app.js")
        assert status == 200, f"static not served from wheel: {status}"
        assert "export" in body or "const" in body or "function" in body, body

        status, body = _get(port, "/", cookie=_SESSION_COOKIE)
        assert status == 200, f"expected rendered grid, got {status}: {body[:500]}"
        assert 'id="grid"' in body, body
        assert "class=\"card\"" in body, body
        assert 'src="/static/app.js"' in body, body
    finally:
        proc.terminate()
        try:
            _ = proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
            _ = proc.wait(timeout=15)
