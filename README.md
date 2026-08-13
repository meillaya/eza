# eza

A self-hosted bookmark manager that stays fast at 10,000+ links.

Search-first, tag-based, no folders. SQLite + FTS5 on the backend, a single
Python process, vanilla JS in the browser. Passkeys instead of passwords
(WebAuthn), with recovery codes and a one-command reset as your escape hatches.

## What it does

- **Search is the front door** — fuzzy full-text search over titles, URLs,
  descriptions, and extracted article text. Operators like `is:unread`,
  `is:dead`, `tag:x`, and `-term` narrow results.
- **Tags, not folders** — one flat list; tag chips AND together. No hierarchy
  to maintain.
- **Knowledge base** — per-bookmark notes with `[[wikilinks]]` and backlinks,
  one-click article extraction, full-page HTML snapshots, and a neighborhood
  graph view.
- **Stays organized on its own** — dead-link sweeps, duplicate detection with
  undo, tag consolidation, optional LLM tagging, and a read-later inbox.
- **Portable** — imports and exports the standard Netscape `bookmarks.html`
  that every browser produces; per-bookmark Markdown export as a guardrail.

## Quick start

Requires Python ≥ 3.11, [uv](https://github.com/astral-sh/uv), and
[just](https://github.com/casey/just) (the task runner).

```bash
just sync   # install dependencies from the lockfile
just run    # start the server on 127.0.0.1:8000
```

Then open **http://localhost:8000/setup** in your browser and register your
first passkey.

> Use `localhost`, not `127.0.0.1`. WebAuthn credentials are bound to the
> origin you register against, and the default relying-party ID is `localhost`.

The `/setup` page will show you **10 one-time recovery codes** — save them.
They're the only way back in if you lose your passkey.

Import your browser bookmarks via the **Import** button, or just start adding.

## Using it

| Where | What |
|---|---|
| `/` | Main grid — 60 cards per page, infinite scroll, type to search |
| `/bookmark/{id}` | Detail page: note body, backlinks, article text, snapshot |
| `/inbox` | Read-later queue (unread bookmarks, newest first) |
| `/graph` | Neighborhood graph of a bookmark's links (1–2 hops) |
| `/dedup` | Duplicate-candidate review + merge (undo-able) |
| `/tags-cleanup` | Tag consolidation candidates + merge |
| `/maintenance` | Dead-link sweep + age-pruning review |

Keyboard: `/` focuses search, `k` opens the quick switcher.

## Configuration

All settings are environment variables; the dev defaults work out of the box.

| Variable | Default | Purpose |
|---|---|---|
| `PUBLIC_ORIGIN` | `http://localhost:8000` | Origin users reach the app at; non-loopback = production (Secure cookies) |
| `WEBAUTHN_RP_ID` | `localhost` / derived host | WebAuthn relying-party ID — must match the origin's host |
| `SECRET_KEY` | insecure dev default | Signs sessions; set a real one (`python -c "import secrets; print(secrets.token_urlsafe(64))"`) |
| `BOOKMARKS_DB` | `<repo>/data/bookmarks.db` | SQLite file location |
| `BACKUP_DIR` / `BACKUP_OFFBOX_DEST` | `<db>/backups` / unset | Backup location + optional offsite copy |
| `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` | unset | For `bookmarks-retag` (LLM tagging) |

## Development

```bash
just test        # Python test suite (pytest + TestClient)
just lint        # ruff
just check       # ty type-check
just build       # build the wheel
just e2e         # browser e2e suite (docker compose, pinned Playwright harness)
```

The Python layer is ~500 tests; the browser layer runs real passkey
ceremonies against a reproducible Playwright/Chromium harness
(`docker compose run --rm e2e bun run test:e2e`).

## Deploy

- **Docker** — multi-stage image, non-root user, healthcheck, monolith binary
  for snapshots: `docker build -t eza .`
- **Railway** — `railway.toml` + a step-by-step runbook in the README history
  of this repo (volume at `/app/data`, custom domain for passkeys).
- **NixOS** — a deployment flake in `nixos/` (hardened systemd unit, Caddy
  with automatic HTTPS, agenix secrets, daily backup timer).

## Backup & recovery

```bash
just backup                     # online SQLite backup + integrity check
scripts/backup.sh verify <file> # restore into a temp path, compare counts
```

- Recovery codes from `/setup` open a scoped re-enrollment session if you lose
  your passkeys.
- `bookmarks-reset-auth` clears everything and returns the app to first-run
  `/setup` (last resort when codes are gone too).

## License

MIT.
