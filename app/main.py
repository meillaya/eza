"""FastAPI app — routes for the bookmark manager."""

from __future__ import annotations

import hmac
import logging
import re
from base64 import urlsafe_b64decode
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import urlparse

from fastapi import FastAPI, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from selectolax.parser import HTMLParser, Node

from . import auth, config, db, fetcher, links, snapshot

log = logging.getLogger("bookmarks")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")

# Browser top-level folders. Their contents are real bookmarks and must be
# imported, but the folder name is too generic to be a useful tag.
_BROWSER_ROOT_FOLDERS = frozenset(
    {
        "Bookmarks bar",
        "Bookmarks",
        "Other bookmarks",
        "Mobile Bookmarks",
    }
)

# Session-manager / "tab save" exports often produce folders whose names
# are timestamps. They re-import the same URLs every time, which floods
# the tag list. We descend into them (their contents are real bookmarks)
# but don't add the timestamp as a tag.
_TIMESTAMP_FOLDER = re.compile(
    r"""
    \bnew\s+folder\b
    |
    \b\d{1,2}\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+\d{4}\b
    |
    \b\d{4}-\d{2}-\d{2}\b
    |
    \b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\w*\s+\d{1,2},?\s+\d{4}\b
    """,
    re.IGNORECASE | re.VERBOSE,
)


def _looks_like_timestamp_folder(name: str) -> bool:
    return bool(_TIMESTAMP_FOLDER.search(name))


ROOT = Path(__file__).resolve().parent.parent
TEMPLATES = Jinja2Templates(directory=str(ROOT / "templates"))


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    yield
    await fetcher.aclose()


app = FastAPI(title="Bookmarks", docs_url=None, redoc_url=None, lifespan=lifespan)
app.mount("/static", StaticFiles(directory=str(ROOT / "static")), name="static")


# ---------------------------------------------------------------------------
# HTML pages
# ---------------------------------------------------------------------------


@app.get("/", response_class=HTMLResponse)
def index(request: Request) -> HTMLResponse:
    """Initial page render. We hand the browser the first 60 bookmarks and let
    JS take over for further pages and search."""
    initial = db.list_bookmarks(limit=60)
    for item in initial:
        item["tags"] = db.get_tags_for_bookmark(item["id"])
    tags = db.all_tags()
    return TEMPLATES.TemplateResponse(
        request,
        "index.html",
        {
            "bookmarks": initial,
            "tags": tags,
            "total": db.count_bookmarks(),
        },
    )


@app.get("/bookmark/{bookmark_id}", response_class=HTMLResponse)
async def bookmark_detail_page(request: Request, bookmark_id: int) -> HTMLResponse:
    """Bookmark detail / reader page (todo 17). The server embeds the stored
    record (extracted_text in the reader section, note_body, tags) so the page
    is readable without JS; app.js drives the note/tags editor and the explicit
    Save. Authed by the global middleware like every other page."""
    bookmark = await db.run_db(db.get_bookmark, bookmark_id)
    if bookmark is None:
        raise HTTPException(status_code=404, detail="Not found")
    return TEMPLATES.TemplateResponse(
        request,
        "detail.html",
        {"bookmark": bookmark},
    )


@app.get("/graph", response_class=HTMLResponse)
async def graph_page(
    request: Request,
    seed: int | None = Query(default=None),
    depth: int = Query(default=1),
) -> HTMLResponse:
    """Graph view page (todo 23): renders the SEED's 1-2 hop neighborhood over
    the links table via the vendored Cytoscape.js browser global. With no
    ``seed`` param the page shows a seed picker (the graph is a view reached
    from the grid/detail, never the primary navigation). ``depth`` defaults to
    1 and is validated to be exactly 1 or 2. Authed by the global middleware
    like every page — no exemption."""
    if depth not in (1, 2):
        raise HTTPException(status_code=400, detail="depth must be 1 or 2")
    bookmark = await db.run_db(db.get_bookmark, seed) if seed is not None else None
    if seed is not None and bookmark is None:
        raise HTTPException(status_code=404, detail="Not found")
    return TEMPLATES.TemplateResponse(
        request, "graph.html", {"seed": bookmark, "depth": depth}
    )


# ---------------------------------------------------------------------------
# First-run setup bootstrap (todo 9). /setup and /api/setup/* are in the
# global unauthenticated-exemption list, so the server-side setup guard is
# enforced IN these endpoints, not by auth middleware.
# ---------------------------------------------------------------------------

# allow: SIZE_OK — _SETUP_PAGE_HTML is a static template (pure data); the
# commit contract for this todo stages only app/{auth,main}.py + tests, so the
# setup page cannot live in its own template file yet.
_SETUP_PAGE_HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Set up your passkey</title>
</head>
<body>
  <h1>Set up your passkey</h1>
  <p>Create a passkey, then save the one-time recovery codes shown once.</p>
  <button id="register" type="button">Create passkey</button>
  <p id="error" style="color:#b00020"></p>
  <h2 hidden>Your one-time recovery codes</h2>
  <pre id="codes" hidden></pre>
  <script>
    const btn = document.getElementById("register");
    const err = document.getElementById("error");
    const codes = document.getElementById("codes");
    btn.addEventListener("click", async () => {
      try {
        err.textContent = "";
        const resp = await fetch("/api/setup/options", { method: "POST" });
        if (resp.status === 403) { err.textContent = "Setup is not available."; return; }
        const options = await resp.json();
        const credential = await navigator.credentials.create({
          publicKey: PublicKeyCredential.parseCreationOptionsFromJSON(options),
        });
        const verify = await fetch("/api/setup/verify", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(credential),
        });
        if (!verify.ok) { err.textContent = "Registration failed (" + verify.status + ")."; return; }
        const result = await verify.json();
        btn.hidden = true;
        codes.hidden = false;
        codes.textContent = result.codes.join("\\n");
      } catch (e) {
        err.textContent = "Setup failed: " + e.message;
      }
    });
  </script>
</body>
</html>
"""


@app.get("/setup", response_class=HTMLResponse)
def setup_page() -> HTMLResponse:
    """First-run bootstrap page. Hidden once any credential exists."""
    if auth.count_credentials() > 0:
        raise HTTPException(status_code=404, detail="Not found")
    return HTMLResponse(_SETUP_PAGE_HTML)


@app.post("/api/setup/options")
def api_setup_options() -> dict:
    """Registration options for the fixed user. Guarded in-endpoint."""
    if not auth.setup_options_allowed():
        raise HTTPException(status_code=403, detail="Setup is not available")
    return auth.registration_options()


@app.post("/api/setup/verify")
async def api_setup_verify(request: Request) -> JSONResponse:
    """Verify the registration, persist the credential, issue codes, create the first session."""
    if not await db.run_db(auth.setup_verify_allowed):
        raise HTTPException(status_code=403, detail="Setup is not available")
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON body") from None
    if not isinstance(body, (str, dict)):
        raise HTTPException(status_code=400, detail="Invalid registration response")
    try:
        codes, session_id = await db.run_db(auth.complete_registration, body)
    except auth.SetupError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    response = JSONResponse(
        {"status": "ok", "codes": codes, "session_id": session_id}
    )
    response.set_cookie(
        key=auth.SESSION_COOKIE_NAME,
        value=session_id,
        max_age=config.SESSION_TTL_SECONDS,
        httponly=True,
        samesite="strict",
        secure=config.IS_PROD,
        path="/",
    )
    return response


@app.post("/api/recovery/redeem")
async def api_recovery_redeem(request: Request) -> Response:
    """Redeem a one-time recovery code (the lockout path).

    The ONLY /api/recovery/* route exempt from auth (it lives in the
    middleware's method+path exemption list, deliberately not the whole
    prefix). A valid unused code opens a recovery-scoped session FIRST, then
    revokes every credential and pre-existing session, then marks the code
    used — see ``auth.redeem_code``. HTML clients get a 303 to /setup (the
    one page the scoped session is allowed to reach); API clients get
    ``{"next": "/setup"}``. Unknown/used codes are 400.
    """
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON body") from None
    code = body.get("code") if isinstance(body, dict) else None
    if not isinstance(code, str) or not code:
        raise HTTPException(status_code=400, detail="Missing recovery code")
    session_id = await db.run_db(auth.redeem_code, code)
    if session_id is None:
        raise HTTPException(
            status_code=400, detail="Unknown or already used recovery code"
        )
    response = (
        RedirectResponse("/setup", status_code=303)
        if "text/html" in request.headers.get("accept", "")
        else JSONResponse({"next": "/setup"})
    )
    response.set_cookie(
        key=auth.SESSION_COOKIE_NAME,
        value=session_id,
        max_age=auth.RECOVERY_SESSION_TTL_SECONDS,
        httponly=True,
        samesite="strict",
        secure=config.IS_PROD,
        path="/",
    )
    return response


# ---------------------------------------------------------------------------
# JSON API
# ---------------------------------------------------------------------------


@app.get("/health")
def health():
    """Deploy probe: the app is up and the database is reachable.

    Deliberately side-effect-free and open: no auth (auth arrives in wave 2 —
    this route must stay in the auth-exemption list), no bookmark data, no
    writes. Just a ``SELECT 1`` round-trip through the per-thread connection.
    """
    try:
        db.get_conn().execute("SELECT 1")
    except Exception:
        log.exception("health check: database unreachable")
        return JSONResponse(
            status_code=503,
            content={"status": "unavailable", "detail": "database unreachable"},
        )
    return {"status": "ok"}


@app.get("/api/autocomplete")
def api_autocomplete(q: str = Query(default="", max_length=200)):
    """Wikilink autocomplete (todo 20).

    Case-insensitive prefix+substring match over bookmark title/url (the
    "alias" behavior — no aliases schema exists), capped at 10, returning
    ``{id, title, url}`` items. Authed by the global middleware like every
    route — this endpoint is deliberately NOT in the exemption list. An
    empty/blank ``q`` yields an empty list, never an error.
    """
    return db.autocomplete(q, limit=10)


@app.get("/api/graph")
async def api_graph(
    seed: int = Query(...),
    depth: int = Query(default=1),
) -> dict:
    """Neighborhood graph (todo 23): the SEED bookmark plus its 1-2 hop
    neighborhood over the links table — NEVER the whole corpus. Returns
    ``{"nodes": [{id, title, url, tags, is_read, indegree}], "edges":
    [{source, target}]}``; edges are directed source→target (the [[wikilink]]
    direction). ``depth`` defaults to 1 and is validated to be exactly 1 or 2.
    Authed by the global middleware — deliberately no exemption. Unknown seed
    → 404.
    """
    if depth not in (1, 2):
        raise HTTPException(status_code=400, detail="depth must be 1 or 2")
    result = await db.run_db(db.graph_neighborhood, seed, depth)
    if result is None:
        raise HTTPException(status_code=404, detail="Not found")
    return result


@app.get("/api/search")
def api_search(
    q: str = Query(default=""),
    tags: str = Query(default=""),  # comma-separated
    offset: int = Query(default=0, ge=0),
    limit: int = Query(default=60, ge=1, le=200),
):
    """Search (todo 18: full content + operators).

    The ``q``/``tags``/``offset``/``limit`` contract is unchanged. ``q`` may
    carry operators parsed by the DB layer: ``tag:name`` (ANDed with the
    ``tags`` parameter), ``is:unread``, ``link:target`` and ``-term``. Each
    result item additionally carries a ~120-char ``snippet`` from the
    best-matching FTS field when ``q`` has plain terms.
    """
    tag_list = [t.strip() for t in tags.split(",") if t.strip()] if tags else []
    items = db.list_bookmarks(q=q, tags=tag_list, limit=limit, offset=offset)
    total = db.count_bookmarks(q=q, tags=tag_list)
    # Hydrate tags for each card on the search path so the frontend stays dumb.
    for item in items:
        item["tags"] = db.get_tags_for_bookmark(item["id"])
    return {"items": items, "total": total, "offset": offset, "limit": limit}


@app.post("/api/bookmarks")
async def api_add_bookmark(
    url: str = Form(...),
    title: str = Form(default=""),
    tags: str = Form(default=""),
):
    url = url.strip()
    if not (url.startswith("http://") or url.startswith("https://")):
        raise HTTPException(status_code=400, detail="URL must start with http(s)://")

    tag_list = [t.strip().lower() for t in tags.split(",") if t.strip()]
    domain = urlparse(url).netloc
    bookmark_id = db.insert_bookmark(
        url=url,
        title=title.strip(),
        domain=domain,
        tags=tag_list,
    )

    # Background-enrich with title/favicon/description. Never block on this.
    fetcher.schedule_enrich(bookmark_id, url)
    # Background content extraction (article text + metadata). Also never
    # blocks the response — same fire-and-forget pattern as enrichment.
    fetcher.schedule_extract(bookmark_id, url)

    return {"id": bookmark_id}


@app.delete("/api/bookmarks/{bookmark_id}")
def api_delete_bookmark(bookmark_id: int):
    if not db.delete_bookmark(bookmark_id):
        raise HTTPException(status_code=404, detail="Not found")
    return {"ok": True}


@app.patch("/api/bookmarks/{bookmark_id}")
async def api_update_bookmark(bookmark_id: int, request: Request) -> dict:
    """Edit a bookmark (todo 17): note_body, title, tags, is_read — any
    combination, applied atomically by db.update_bookmark.

    The note_body path keeps the todo-15 behavior: [[wikilinks]] are parsed
    and the links table re-synced inside the same transaction. The tags list
    is authoritative (tags dropped from it are unlinked). An empty title is
    rejected 400 before anything is written. The backend is stateless per
    PATCH — there is deliberately no autosave endpoint; the UI saves
    explicitly.
    """
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON body") from None
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="Invalid JSON body")
    updates: dict[str, object] = {}
    if "note_body" in body:
        if not isinstance(body["note_body"], str):
            raise HTTPException(status_code=400, detail="note_body must be a string")
        updates["note_body"] = body["note_body"]
    if "title" in body:
        title = body["title"]
        if not isinstance(title, str) or not title.strip():
            raise HTTPException(status_code=400, detail="title must be a non-empty string")
        updates["title"] = title.strip()
    if "tags" in body:
        tags = body["tags"]
        if not isinstance(tags, list) or not all(isinstance(t, str) for t in tags):
            raise HTTPException(status_code=400, detail="tags must be a list of strings")
        updates["tags"] = tags
    if "is_read" in body:
        is_read = body["is_read"]
        if isinstance(is_read, int) and is_read in (0, 1):
            updates["is_read"] = is_read
        else:
            raise HTTPException(status_code=400, detail="is_read must be 0 or 1")
    if not updates:
        raise HTTPException(status_code=400, detail="No editable fields provided")
    if not await db.run_db(db.update_bookmark, bookmark_id, **updates):
        raise HTTPException(status_code=404, detail="Not found")
    return {"ok": True}


@app.get("/api/bookmarks/{bookmark_id}")
async def api_bookmark_detail(bookmark_id: int) -> dict:
    """Full bookmark detail (todo 17): the complete record plus note_body,
    extracted_text, tags and a backlinks summary (linked + unlinked mentions,
    reusing links.get_backlinks). The reader view renders stored
    ``extracted_text`` — this is a minimal reader display, not a Pocket-style
    reading app."""
    bookmark = await db.run_db(db.get_bookmark, bookmark_id)
    if bookmark is None:
        raise HTTPException(status_code=404, detail="Not found")
    backlinks = await db.run_db(links.get_backlinks, bookmark_id)
    bookmark["backlinks"] = backlinks if backlinks is not None else {"linked": [], "unlinked": []}
    return bookmark


@app.get("/api/bookmarks/{bookmark_id}/backlinks")
def api_backlinks(bookmark_id: int) -> dict:
    """Linked + unlinked mentions of a bookmark. Authed by the global
    middleware (no exemption); both lists carry the link-it payload
    (source_id + line_number) plus a context snippet."""
    result = links.get_backlinks(bookmark_id)
    if result is None:
        raise HTTPException(status_code=404, detail="Not found")
    return result


@app.post("/api/bookmarks/{bookmark_id}/snapshot")
async def api_capture_snapshot(bookmark_id: int) -> dict:
    """Capture a single-file HTML snapshot of a bookmark on demand.

    Runs the monolith binary as a subprocess (30s bound) on a worker thread —
    never inside a write transaction (todo-4 rule: no network/process I/O in
    BEGIN IMMEDIATE) — and records the result in ``snapshot_path``, falling
    back to a Wayback availability URL when monolith fails. On-demand only:
    saving a bookmark never triggers a snapshot. Authed + CSRF-checked by the
    global middleware.
    """
    bookmark = await db.run_db(db.get_bookmark, bookmark_id)
    if bookmark is None:
        raise HTTPException(status_code=404, detail="Not found")
    return await db.run_db(snapshot.capture_snapshot, bookmark_id, bookmark["url"])


@app.get("/api/tags")
def api_tags():
    return {"tags": db.all_tags()}


# ---------------------------------------------------------------------------
# Browser bookmark importer (Netscape bookmark-file format)
# ---------------------------------------------------------------------------


@app.post("/api/import")
async def api_import(file: UploadFile = File(...)):
    """Import a browser bookmarks.html export (Netscape format used by all
    major browsers). Folder names become tags. Imports are batched into a
    single SQLite transaction for speed (~100x faster than per-row inserts).
    """
    raw = await file.read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("latin-1", errors="replace")

    html = HTMLParser(text)
    items: list[dict] = []

    def walk(dl_node: Node, folder_tags: list[str]) -> None:
        """Walk a <DL> node's direct children. Each <DT> child is either a
        link (<DT><A>…</A></DT>) or a folder
        (<DT><H3>name</H3><DL>…nested…</DL></DT>). Critically, a link <A>
        must be a DIRECT child of the <DT> — using css_first('a') would
        reach into the DT's nested <DL> and misclassify folders as links.

        selectolax's .iter() yields direct children only, so we use that to
        classify. We recurse explicitly into nested <DL>s to track the
        folder tag stack.
        """
        # .iter() yields the node itself then its direct children. Skip the
        # self-entry (index 0) and walk the rest.
        children = list(dl_node.iter())
        for child in children[1:]:
            if (child.tag or "").lower() != "dt":
                continue
            # Find the link or folder among the DT's *direct* children.
            direct_a: Node | None = None
            direct_h3: Node | None = None
            nested_dl: Node | None = None
            for kid in child.iter():
                ktag = (kid.tag or "").lower()
                if ktag == "a" and direct_a is None:
                    direct_a = kid
                elif ktag == "h3" and direct_h3 is None:
                    direct_h3 = kid
                elif ktag == "dl" and nested_dl is None:
                    nested_dl = kid

            if direct_a is not None and direct_h3 is None:
                href_attr = direct_a.attributes.get("href")
                href = (href_attr or "").strip()
                if href.startswith(("http://", "https://")):
                    items.append(
                        {
                            "url": href,
                            "title": (direct_a.text() or "").strip(),
                            "domain": urlparse(href).netloc,
                            "tags": folder_tags,
                        }
                    )
                continue

            if direct_h3 is None:
                continue

            folder_name = (direct_h3.text() or "").strip()
            if not folder_name:
                continue

            # Top-level browser folders ("Bookmarks bar", etc.) and
            # timestamp-named session-manager folders are not useful as
            # tags — but their children are real bookmarks, so we recurse
            # without adding the folder name.
            if folder_name in _BROWSER_ROOT_FOLDERS or _looks_like_timestamp_folder(folder_name):
                new_tags = folder_tags
            else:
                new_tags = [*folder_tags, folder_name.lower()]
            if nested_dl is not None:
                walk(nested_dl, new_tags)

    # Top-level <dl>
    top = html.css_first("dl")
    if top is not None:
        walk(top, [])

    inserted = db.bulk_insert_bookmarks(
        items, enrich_callback=fetcher.schedule_extract_for_url
    )
    return {"inserted": inserted, "found": len(items)}


# ---------------------------------------------------------------------------
# Usernameless login + sessions + CSRF + global route guard (todo 10)
# ---------------------------------------------------------------------------
#
# allow: SIZE_OK — this module is the single route file and the todo-10 commit
# contract stages only app/{auth,main}.py + tests; splitting it would force a
# new module outside the staging list. The size is already inherited from the
# setup bootstrap (todo 9).

_CSRF_COOKIE_NAME = "csrf_token"

# allow: SIZE_OK — _LOGIN_PAGE_HTML is a static template (pure data), the same
# pattern as _SETUP_PAGE_HTML above.
_LOGIN_PAGE_HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Sign in</title>
</head>
<body>
  <h1>Bookmarks</h1>
  <p>Sign in with your passkey.</p>
  <a id="setup" href="/setup" hidden>Set up your passkey</a>
  <p><button id="login" type="button">Sign in with passkey</button></p>
  <p id="error" style="color:#b00020"></p>
  <script>
    (async () => {
      try {
        const probe = await fetch("/api/setup/options", { method: "POST" });
        if (probe.status === 200) {
          document.getElementById("setup").hidden = false;
        }
      } catch (_) {
        // probe offline — keep the /setup link hidden
      }
    })();
    const btn = document.getElementById("login");
    const err = document.getElementById("error");
    btn.addEventListener("click", async () => {
      try {
        err.textContent = "";
        const options = await (await fetch("/api/auth/options", { method: "POST" })).json();
        const credential = await navigator.credentials.get({
          publicKey: PublicKeyCredential.parseRequestOptionsFromJSON(options),
        });
        const verify = await fetch("/api/auth/verify", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(credential),
        });
        if (!verify.ok) { err.textContent = "Sign-in failed (" + verify.status + ")."; return; }
        location.reload();
      } catch (e) {
        err.textContent = "Sign-in failed: " + e.message;
      }
    });
  </script>
</body>
</html>
"""

# allow: SIZE_OK — _ACCOUNT_PAGE_HTML is a static template (pure data), the
# same pattern as _SETUP_PAGE_HTML and _LOGIN_PAGE_HTML above.
_ACCOUNT_PAGE_HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Account</title>
</head>
<body>
  <h1>Account</h1>
  <h2>Passkeys</h2>
  <ul id="credentials"></ul>
  <h2>Recovery codes</h2>
  <p>Rotating your recovery codes invalidates every code issued before this moment.</p>
  <button id="regenerate" type="button">Regenerate recovery codes</button>
  <p id="error" style="color:#b00020"></p>
  <pre id="codes" hidden></pre>
  <script>
    function csrfToken() {
      const c = document.cookie.split("; ").find((c) => c.startsWith("csrf_token="));
      return c ? c.slice("csrf_token=".length) : "";
    }
    const list = document.getElementById("credentials");
    (async () => {
      try {
        const resp = await fetch("/api/credentials");
        if (!resp.ok) { list.textContent = "Failed to load credentials."; return; }
        const { credentials } = await resp.json();
        if (!credentials.length) { list.textContent = "No passkeys enrolled."; return; }
        for (const c of credentials) {
          const li = document.createElement("li");
          const name = c.nickname || "Passkey";
          li.textContent = name + (c.backup_eligible ? " (backup eligible)" : "");
          list.appendChild(li);
        }
      } catch (e) { list.textContent = "Failed to load credentials: " + e.message; }
    })();
    const btn = document.getElementById("regenerate");
    const err = document.getElementById("error");
    const codes = document.getElementById("codes");
    btn.addEventListener("click", async () => {
      try {
        err.textContent = "";
        const resp = await fetch("/api/recovery/regenerate", {
          method: "POST",
          headers: { "X-CSRF-Token": csrfToken() },
        });
        if (!resp.ok) { err.textContent = "Regeneration failed (" + resp.status + ")."; return; }
        const result = await resp.json();
        codes.hidden = false;
        codes.textContent = result.codes.join("\\n");
      } catch (e) { err.textContent = "Regeneration failed: " + e.message; }
    });
  </script>
</body>
</html>
"""

# The auth-exemption list. Prefix matches, exact paths, and method+path
# exceptions. POST /api/recovery/redeem is exempt as a single method+path
# entry — deliberately NOT the whole /api/recovery prefix, so
# /api/recovery/regenerate (todo 12) stays behind auth.
_EXEMPT_PREFIXES = ("/api/setup/", "/api/auth/", "/static")
_EXEMPT_EXACT_PATHS = frozenset({"/setup", "/health"})
_EXEMPT_METHOD_PATHS = frozenset({("POST", "/api/recovery/redeem")})

# Routes a recovery-scoped session may use: the re-enrollment UI plus redeem.
# Deliberately NARROWER than the auth-exemption list — a recovery session must
# never touch /api/auth/*, /health or any bookmark route.
_RECOVERY_PREFIXES = ("/api/setup/",)
_RECOVERY_GET_PATHS = frozenset({"/setup"})
_RECOVERY_METHOD_PATHS = frozenset({("POST", "/api/recovery/redeem")})

_CSRF_METHODS = frozenset({"POST", "PUT", "PATCH", "DELETE"})


def _is_exempt(method: str, path: str) -> bool:
    if path in _EXEMPT_EXACT_PATHS:
        return True
    if path.startswith(_EXEMPT_PREFIXES):
        return True
    return (method, path) in _EXEMPT_METHOD_PATHS


def _recovery_allowed(method: str, path: str) -> bool:
    if method == "GET" and path in _RECOVERY_GET_PATHS:
        return True
    if path.startswith(_RECOVERY_PREFIXES):
        return True
    return (method, path) in _RECOVERY_METHOD_PATHS


# allow: SIZE_OK — _RECOVERY_403_HTML is a static template (pure data), the
# same pattern as _SETUP_PAGE_HTML and _LOGIN_PAGE_HTML above.
_RECOVERY_403_HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Recovery in progress</title>
</head>
<body>
  <h1>Passkey recovery</h1>
  <p>Your session is limited to the recovery re-enrollment flow.</p>
  <p><a href="/setup">Continue with /setup</a></p>
</body>
</html>
"""


def _recovery_forbidden_response(request: Request) -> Response:
    """403 for a recovery-scoped session on a disallowed route.

    HTML clients get a page whose only job is linking to /setup (the one
    destination the scoped session is allowed to reach); API clients keep the
    JSON detail.
    """
    if "text/html" in request.headers.get("accept", ""):
        return HTMLResponse(_RECOVERY_403_HTML, status_code=403)
    return JSONResponse(status_code=403, content={"detail": "Forbidden"})


def _unauthorized_response(request: Request) -> Response:
    """401 for an unauthenticated request: JSON for API clients, the minimal
    usernameless login page for HTML clients (detected via the Accept header).
    """
    if "text/html" in request.headers.get("accept", ""):
        return HTMLResponse(_LOGIN_PAGE_HTML, status_code=401)
    return JSONResponse(status_code=401, content={"detail": "Not authenticated"})


@app.middleware("http")
async def require_auth(request: Request, call_next) -> Response:
    """Global route guard: every route requires a valid session except the
    explicit exemption list. Pure middleware, so routes registered in later
    waves (todos 15,17,18,23,...) are protected by default.

    Order: (1) a recovery-scoped session is pinned to /api/setup/*, GET /setup
    and POST /api/recovery/redeem (403 everywhere else, including /api/auth/*);
    (2) the auth-exemption list passes through; (3) no session -> 401 (login
    page for HTML, JSON for API); (4) mutating requests must echo the session's
    csrf_token in X-CSRF-Token (constant-time compare), else 403.
    """
    session = auth.get_session(request.cookies.get(auth.SESSION_COOKIE_NAME))
    request.state.session = session
    request.state.scope = session["scope"] if session else None

    if session is not None and session["scope"] == "recovery":
        if not _recovery_allowed(request.method, request.url.path):
            return _recovery_forbidden_response(request)
        return await call_next(request)

    if _is_exempt(request.method, request.url.path):
        return await call_next(request)

    if session is None:
        return _unauthorized_response(request)

    if request.method in _CSRF_METHODS:
        provided = request.headers.get("X-CSRF-Token", "")
        if not hmac.compare_digest(session["csrf_token"], provided):
            return JSONResponse(status_code=403, content={"detail": "CSRF token mismatch"})

    return await call_next(request)


def _set_auth_cookies(response: Response, session_id: str, csrf_token: str) -> None:
    """Set the httpOnly session cookie and the non-httpOnly csrf cookie.

    SameSite=Strict on both; Secure follows the prod predicate (todo 2).
    Modern browsers treat 127.0.0.1/localhost as a secure context, so the
    Secure flag can stay on in dev too.
    """
    response.set_cookie(
        key=auth.SESSION_COOKIE_NAME,
        value=session_id,
        max_age=config.SESSION_TTL_SECONDS,
        httponly=True,
        samesite="strict",
        secure=config.IS_PROD,
        path="/",
    )
    response.set_cookie(
        key=_CSRF_COOKIE_NAME,
        value=csrf_token,
        max_age=config.SESSION_TTL_SECONDS,
        httponly=False,
        samesite="strict",
        secure=config.IS_PROD,
        path="/",
    )


@app.post("/api/auth/options")
def api_auth_options() -> dict:
    """Usernameless (discoverable) authentication options for login."""
    return auth.authentication_options()


@app.post("/api/auth/verify")
async def api_auth_verify(request: Request) -> JSONResponse:
    """Verify an assertion and open a normal-scoped session (login)."""
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON body") from None
    if not isinstance(body, (str, dict)):
        raise HTTPException(status_code=400, detail="Invalid authentication response")
    try:
        session_id, csrf_token = await db.run_db(auth.complete_login, body)
    except auth.LoginError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    response = JSONResponse({"status": "ok", "session_id": session_id})
    _set_auth_cookies(response, session_id, csrf_token)
    return response


@app.post("/api/auth/logout")
def api_auth_logout(request: Request) -> JSONResponse:
    """Delete the session and clear both cookies."""
    auth.logout(request.cookies.get(auth.SESSION_COOKIE_NAME))
    response = JSONResponse({"ok": True})
    response.delete_cookie(auth.SESSION_COOKIE_NAME, path="/")
    response.delete_cookie(_CSRF_COOKIE_NAME, path="/")
    return response


# ---------------------------------------------------------------------------
# Credential management + recovery-code regeneration (todo 12). All four routes
# are authed: the global middleware 401s unauth calls (regenerate is NOT in the
# exemption list — only POST /api/recovery/redeem is) and CSRF-checks the
# mutating writes.
# ---------------------------------------------------------------------------


def _credential_id_from_b64url(value: str) -> bytes | None:
    """Decode a URL-safe-base64 credential id from a path segment.

    ``binascii.Error`` is a ``ValueError`` subclass, so a single catch covers
    malformed ids (bad alphabet, bad padding).
    """
    try:
        return urlsafe_b64decode(value + "=" * (-len(value) % 4))
    except ValueError:
        return None


@app.get("/api/credentials")
def api_list_credentials() -> dict:
    """List enrolled passkeys: id, nickname, created_at, backup_eligible, last_used_at."""
    return {"credentials": auth.list_credentials()}


@app.patch("/api/credentials/{credential_id}")
async def api_rename_credential(credential_id: str, request: Request) -> dict:
    """Rename a passkey (nickname shown on the account page)."""
    raw_id = _credential_id_from_b64url(credential_id)
    if raw_id is None:
        raise HTTPException(status_code=404, detail="Not found")
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON body") from None
    nickname = body.get("nickname") if isinstance(body, dict) else None
    if not isinstance(nickname, str):
        raise HTTPException(status_code=400, detail="nickname must be a string")
    if not await db.run_db(auth.rename_credential, raw_id, nickname.strip()):
        raise HTTPException(status_code=404, detail="Not found")
    return {"ok": True}


@app.delete("/api/credentials/{credential_id}")
async def api_delete_credential(credential_id: str) -> dict:
    """Revoke a passkey. The last credential cannot be revoked: the recovery
    path is the only way back, so that delete is blocked with a 400."""
    raw_id = _credential_id_from_b64url(credential_id)
    if raw_id is None:
        raise HTTPException(status_code=404, detail="Not found")
    try:
        deleted = await db.run_db(auth.delete_credential, raw_id)
    except auth.LastCredentialError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if not deleted:
        raise HTTPException(status_code=404, detail="Not found")
    return {"ok": True}


@app.post("/api/recovery/regenerate")
async def api_recovery_regenerate() -> dict:
    """Rotate recovery codes: every prior hash is deleted first, then 10 new
    codes are issued and returned exactly once (authed-only)."""
    codes = await db.run_db(auth.regenerate_codes)
    return {"codes": codes}


@app.get("/account")
def account_page() -> HTMLResponse:
    """Credential management page: lists passkeys and offers code regeneration."""
    return HTMLResponse(_ACCOUNT_PAGE_HTML)


def main() -> None:
    """Entry point for the `bookmarks-server` console script."""
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host="127.0.0.1",
        port=8000,
        log_level="info",
    )
