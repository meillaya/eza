"""FastAPI app — routes for the bookmark manager."""

from __future__ import annotations

import logging
import re
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import urlparse

from fastapi import FastAPI, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from selectolax.parser import HTMLParser, Node

from . import db, fetcher

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


@app.get("/api/search")
def api_search(
    q: str = Query(default=""),
    tags: str = Query(default=""),  # comma-separated
    offset: int = Query(default=0, ge=0),
    limit: int = Query(default=60, ge=1, le=200),
):
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

    return {"id": bookmark_id}


@app.delete("/api/bookmarks/{bookmark_id}")
def api_delete_bookmark(bookmark_id: int):
    if not db.delete_bookmark(bookmark_id):
        raise HTTPException(status_code=404, detail="Not found")
    return {"ok": True}


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

    inserted = db.bulk_insert_bookmarks(items)
    return {"inserted": inserted, "found": len(items)}


def main() -> None:
    """Entry point for the `bookmarks-server` console script."""
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host="127.0.0.1",
        port=8000,
        log_level="info",
    )
