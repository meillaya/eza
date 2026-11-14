#!/usr/bin/env bash
# Documentation consistency checks.
#
#   devenv shell -- docs        # or: bash scripts/check-docs.sh
#
# The checks are intentionally boring and mechanical: they catch the two drift
# classes that have already bitten this repository (a source directory missing
# from the AGENTS.md layout, and the version string copied into deployment
# files) and, once the generators exist, reject stale generated reference docs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  printf 'check-docs: %s\n' "$*" >&2
  exit 1
}

# ------------------------------------------------------------------ layout ---
# AGENTS.md is the map new contributors and agents read first. Every directory
# listed in its Layout block must exist, and every tracked source directory must
# be listed there.
layout_block="$(awk '/^## Layout/{flag=1} /^## Commands/{flag=0} flag' AGENTS.md)"
[ -n "$layout_block" ] || fail "AGENTS.md has no Layout block"

listed_dirs="$(printf '%s\n' "$layout_block" | sed -n 's/^\([A-Za-z0-9_-][A-Za-z0-9_-]*\)\/.*$/\1/p')"
[ -n "$listed_dirs" ] || fail "AGENTS.md Layout block lists no directories"

while IFS= read -r dir; do
  [ -d "$dir" ] || fail "AGENTS.md lists $dir/ in the layout but the directory does not exist"
done <<<"$listed_dirs"

for dir in core server web web-logic static spec nix deploy docs tests scripts extension sidecar; do
  [ -d "$dir" ] || continue
  if ! printf '%s\n' "$listed_dirs" | grep -qx "$dir"; then
    fail "AGENTS.md Layout is missing $dir/"
  fi
done

# ----------------------------------------------------------------- version ---
# One version, many copies: flake.nix is the source of truth and version.sh
# knows where the copies live.
bash scripts/version.sh --check || fail "version drift between flake.nix and its copies"

# -------------------------------------------------------- generated docs -----
# Route and configuration reference tables are generated from the Haskell
# definitions, never hand-edited. A generator that cannot be found is an error
# only when the generated file is tracked, so this check works both before and
# after the generator lands.
if [ -f docs/generated/routes.md ]; then
  tmp="$(mktemp)"
  if ! cabal run -v0 eza-bookmarks -- routes --markdown >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    fail "could not generate the route reference (cabal run eza-bookmarks -- routes --markdown)"
  fi
  if ! diff -u docs/generated/routes.md "$tmp"; then
    rm -f "$tmp"
    fail "docs/generated/routes.md is stale; regenerate it with 'cabal run eza-bookmarks -- routes --markdown > docs/generated/routes.md'"
  fi
  rm -f "$tmp"
fi

if [ -f docs/generated/env.md ]; then
  tmp="$(mktemp)"
  if ! cabal run -v0 eza-bookmarks -- env --markdown >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    fail "could not generate the environment reference (cabal run eza-bookmarks -- env --markdown)"
  fi
  if ! diff -u docs/generated/env.md "$tmp"; then
    rm -f "$tmp"
    fail "docs/generated/env.md is stale; regenerate it with 'cabal run eza-bookmarks -- env --markdown > docs/generated/env.md'"
  fi
  rm -f "$tmp"
fi

echo "check-docs: ok"
