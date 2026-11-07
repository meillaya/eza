# Bookmarks — one task runner (plan todo 39). Install `just` from
# https://github.com/casey/just (cargo install just, a prebuilt binary, or
# `nix run nixpkgs#just`). There is deliberately NO Makefile.

# Install dependencies from the lockfile (reproducible: fails on drift)
sync:
    uv sync --locked

# Run the Python test suite (pytest + TestClient layer)
test:
    uv run pytest -p no:cacheprovider -q

# Lint with ruff
lint:
    uv run ruff check .

# Type-check with ty
check:
    uv run ty check

# Build the wheel + sdist
build:
    uv build

# Run the local server (open http://localhost:8000, NOT 127.0.0.1)
run:
    uv run bookmarks-server

# Online SQLite backup into data/backups (integrity-checked, pruned)
backup:
    uv run bookmarks-backup

# Export the whole library as a Netscape bookmarks.html
export:
    uv run bookmarks-export

# Initialize the local database (schema + migrations) on first run
seed:
    uv run python -c "from app import db; db.get_conn(); print('database initialized')"

# Browser end-to-end suite via the pinned Docker harness (Chromium + WebKit)
e2e:
    docker compose run --rm e2e bun run test:e2e

# Browser end-to-end suite via the Nix devshell (repo-root flake.nix)
e2e-nix:
    nix develop --command bun run test:e2e

# Default: run the Python test suite
default: test
