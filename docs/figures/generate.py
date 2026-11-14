#!/usr/bin/env python3
"""Generate the eza Excalidraw figures.

Every figure is deterministic. Run this file, then render each scene with
excalidraw render. The PNGs live next to the scenes.
"""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent

PALETTE = {
    "blue": ("#1971c2", "#d0ebff"),
    "cuda": ("#e8590c", "#ffe8cc"),
    "hip": ("#2f9e44", "#d3f9d8"),
    "purple": ("#9c36b5", "#f3d9fa"),
    "orange": ("#f08c00", "#fff3bf"),
    "red": ("#e03131", "#ffe3e3"),
    "teal": ("#0c8599", "#c5f6fa"),
    "gray": ("#495057", "#f1f3f5"),
}

INK = "#1e1e1e"
WHITE = "#ffffff"

_counter = 0
_seed = 1000


def _next_id(prefix):
    global _counter
    _counter += 1
    return f"{prefix}_{_counter}"


def _next_seed():
    global _seed
    _seed += 1
    return _seed


def _base(kind, element_id, x, y, width, height, stroke, fill):
    return {
        "id": element_id,
        "type": kind,
        "x": x,
        "y": y,
        "width": width,
        "height": height,
        "angle": 0,
        "strokeColor": stroke,
        "backgroundColor": fill,
        "fillStyle": "hachure",
        "strokeWidth": 2,
        "strokeStyle": "solid",
        "roughness": 2,
        "opacity": 100,
        "groupIds": [],
        "frameId": None,
        "roundness": {"type": 3},
        "seed": _next_seed(),
        "version": 1,
        "versionNonce": _next_seed(),
        "isDeleted": False,
        "boundElements": [],
        "updated": 1,
        "link": None,
        "locked": False,
    }


def _text_common(text, font_size, width, height, text_align="center", vertical="middle"):
    return {
        "text": text,
        "fontSize": font_size,
        "fontFamily": 1,
        "textAlign": text_align,
        "verticalAlign": vertical,
        "originalText": text,
        "lineHeight": 1.25,
        "autoResize": True,
        "containerId": None,
        "width": width,
        "height": height,
    }


def _free_text(text, x, y, size, width, height, align="left"):
    element = _base("text", _next_id("text"), x, y, width, height, INK, "transparent")
    element.update(_text_common(text, size, width, height, align, "top"))
    return element


def _box(label, x, y, width, height, role, font_size=22):
    stroke, fill = PALETTE[role]
    shape = _base("rectangle", _next_id("box"), x, y, width, height, stroke, fill)
    text_id = _next_id("label")
    shape["boundElements"] = [{"type": "text", "id": text_id}]
    text = _base("text", text_id, x + 12, y + 12, width - 24, height - 24, INK, "transparent")
    text.update(_text_common(label, font_size, width - 24, height - 24))
    text["containerId"] = shape["id"]
    return [shape, text]


def _arrow(x1, y1, x2, y2, label):
    elements = []
    arrow_id = _next_id("arrow")
    dx = x2 - x1
    dy = y2 - y1
    arrow = _base("arrow", arrow_id, x1, y1, abs(dx), abs(dy), "#495057", "transparent")
    arrow.update(
        {
            "points": [[0, 0], [dx, dy]],
            "lastCommittedPoint": None,
            "startBinding": None,
            "endBinding": None,
            "startArrowhead": None,
            "endArrowhead": "arrow",
            "roundness": {"type": 2},
        }
    )
    elements.append(arrow)
    mid_x = x1 + dx / 2
    mid_y = y1 + dy / 2
    width = max(64, len(label) * 10)
    label_el = _free_text(label, mid_x - width / 2, mid_y - 26, 16, width, 24, "center")
    elements.append(label_el)
    return elements


def _title(text):
    return _free_text(text, 40, 28, 32, 1400, 44)


def _note(text):
    return [_free_text(text, 40, 840, 18, 1420, 80)]


def _scene(elements):
    return {
        "type": "excalidraw",
        "version": 2,
        "source": "https://eza.local/docs/figures/generate.py",
        "elements": elements,
        "appState": {
            "gridSize": None,
            "viewBackgroundColor": WHITE,
            "exportBackground": True,
        },
        "files": {},
    }


def architecture():
    elements = [_title("One process, one control database, one library per account")]
    elements += _box("Browser: Miso WASM", 60, 150, 300, 110, "blue")
    elements += _box("Static WASM assets", 60, 340, 300, 100, "gray")
    elements += _box("Warp and WAI", 470, 150, 300, 110, "purple")
    elements += _box("Passwords, passkeys, CSRF", 470, 340, 300, 100, "red")
    elements += _box("JSON API routes", 470, 520, 300, 100, "purple")
    elements += _box("Control database", 880, 150, 300, 100, "teal")
    elements += _box("Library SQLite WAL + FTS5", 880, 340, 300, 100, "teal")
    elements += _box("Background workers", 880, 520, 300, 100, "orange")
    elements += _arrow(360, 205, 470, 205, "HTTP JSON")
    elements += _arrow(360, 390, 470, 260, "assets")
    elements += _arrow(620, 260, 620, 340, "guard")
    elements += _arrow(620, 440, 620, 520, "session")
    elements += _arrow(770, 390, 880, 200, "accounts")
    elements += _arrow(770, 570, 880, 390, "SQL")
    elements += _arrow(1030, 440, 1030, 520, "jobs")
    elements += _note("Warp resolves the account in the control database, then opens its library. Each library starts enrichment, webhook and favicon workers.")
    return _scene(elements)


def import_figure():
    elements = [_title("The export collapses to 8,988 rows")]
    elements += _box("9,457 anchors", 60, 150, 300, 100, "blue")
    elements += _box("Netscape parser", 470, 150, 300, 110, "purple")
    elements += _box("8,988 bookmarks", 880, 150, 300, 100, "teal")
    elements += _box("Folder stack to tags", 470, 360, 300, 100, "orange")
    elements += _box("75 tags", 880, 360, 300, 100, "teal")
    elements += _arrow(360, 200, 470, 200, "decode")
    elements += _arrow(770, 200, 880, 200, "insert")
    elements += _arrow(620, 260, 620, 360, "walk")
    elements += _arrow(770, 410, 880, 410, "union")
    elements += _note("9,457 anchors; 4 non-http skipped; 9,453 http anchors minus 465 duplicates leaves 8,988 rows. 75 tags and 21,316 links.")
    return _scene(elements)


def search_figure():
    elements = [_title("Search combines FTS, tags, and rank")]
    elements += _box("Query string", 60, 230, 300, 100, "blue")
    elements += _box("Operator parser", 470, 150, 300, 100, "purple")
    elements += _box("Tag AND filter", 470, 400, 300, 100, "orange")
    elements += _box("FTS5 MATCH", 880, 150, 300, 100, "orange")
    elements += _box("bm25 rank", 880, 400, 300, 100, "teal")
    elements += _box("Snippet window", 880, 600, 300, 100, "gray")
    elements += _arrow(360, 280, 470, 230, "parse")
    elements += _arrow(770, 200, 880, 200, "terms")
    elements += _arrow(620, 250, 620, 400, "tags")
    elements += _arrow(1030, 250, 1030, 400, "score")
    elements += _arrow(770, 450, 880, 450, "keep")
    elements += _arrow(1030, 500, 1030, 600, "top N")
    elements += _note('fts = "tok1"* AND "tok2"*; tag_ok = COUNT(DISTINCT tag_id) = N; order = bm25 then created_at')
    return _scene(elements)


def main():
    for name, builder in [
        ("architecture", architecture),
        ("import", import_figure),
        ("search", search_figure),
    ]:
        scene = builder()
        path = ROOT / f"{name}.excalidraw"
        path.write_text(json.dumps(scene, indent=2) + "\n")
        print(path)


if __name__ == "__main__":
    main()
