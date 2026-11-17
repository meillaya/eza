#!/usr/bin/env python3
"""Check that local images and links in README.md and docs/**/*.md exist.

This is the documentation drift gate that catches a moved or deleted figure:
the README wordmark, the architecture/import/search figures, screenshots and
cross-document links are all checked as file paths relative to the document that
references them. External URLs, anchors, absolute site paths, and templated
targets are skipped; Markdown fenced code blocks are ignored.

Usage:
    python3 scripts/check-doc-links.py [ROOT]

ROOT defaults to the repository root (the parent of this script's directory) so
the command works from a checkout and from check-docs.sh. Exits non-zero and
lists every missing target when a reference is broken.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

# `\![alt](target)` with an optional Markdown title. The target may not contain
# whitespace; the repository uses plain relative paths without spaces.
IMAGE_RE = re.compile(r"!\[[^\]]*\]\(\s*([^)\s]+)")
# `[text](target)`, but not the image form (the negative look-behind).
LINK_RE = re.compile(r"(?<!!)\[[^\]]*\]\(\s*([^)\s]+)")
IMG_TAG_RE = re.compile(r"<img\b[^>]*?\bsrc\s*=\s*([\"'])(.*?)\1", re.IGNORECASE | re.DOTALL)
SRCSET_RE = re.compile(r"\bsrcset\s*=\s*([\"'])(.*?)\1", re.IGNORECASE | re.DOTALL)
SCHEME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")


def documents(root: Path) -> list[Path]:
    found = []
    readme = root / "README.md"
    if readme.is_file():
        found.append(readme)
    docs = root / "docs"
    if docs.is_dir():
        found.extend(sorted(docs.rglob("*.md")))
    return found


def candidate_targets(line: str) -> list[str]:
    targets = IMAGE_RE.findall(line) + LINK_RE.findall(line)
    targets.extend(match[1] for match in IMG_TAG_RE.findall(line))
    for _quote, value in SRCSET_RE.findall(line):
        for candidate in value.split(","):
            token = candidate.strip().split(" ")[0] if candidate.strip() else ""
            if token:
                targets.append(token)
    return targets


def check_target(document: Path, root: Path, target: str) -> str | None:
    """Return an error message for a broken local target, else None."""
    target = target.strip()
    if target.startswith("<") and target.endswith(">"):
        target = target[1:-1]
    if not target or target.startswith("#") or target.startswith("//"):
        return None
    # Site-absolute paths are routes, not files in the checkout.
    if target.startswith("/"):
        return None
    if SCHEME_RE.match(target):
        return None
    if any(token in target for token in ("{", "}", "<", ">")):
        return None

    path = unquote(urlsplit(target).path)
    if not path:
        return None
    resolved = (document.parent / path).resolve()
    if resolved.exists():
        return None
    try:
        shown_source = str(document.relative_to(root))
    except ValueError:
        shown_source = str(document)
    return f"{shown_source}: missing local target '{target}'"


def main(argv: list[str]) -> int:
    if len(argv) > 2:
        print("usage: check-doc-links.py [ROOT]", file=sys.stderr)
        return 2
    root = Path(argv[1]) if len(argv) == 2 else Path(__file__).resolve().parent.parent
    root = root.resolve()

    documents_checked = documents(root)
    if not documents_checked:
        print("check-doc-links: no README.md or docs/*.md found", file=sys.stderr)
        return 1

    problems: list[str] = []
    targets_checked = 0
    for document in documents_checked:
        in_fence = False
        for line_number, line in enumerate(document.read_text(encoding="utf-8").splitlines(), start=1):
            stripped = line.strip()
            if stripped.startswith("```") or stripped.startswith("~~~"):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            for target in candidate_targets(line):
                message = check_target(document, root, target)
                if message is not None:
                    problems.append(f"{message} (line {line_number})")
                targets_checked += 1

    if problems:
        for problem in problems:
            print(f"check-doc-links: {problem}", file=sys.stderr)
        print(
            f"check-doc-links: {len(problems)} broken reference(s) in "
            f"{len(documents_checked)} documents; restore the file or update the reference",
            file=sys.stderr,
        )
        return 1

    print(
        f"check-doc-links: {targets_checked} local target(s) in "
        f"{len(documents_checked)} document(s) exist"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
